require "rails_helper"

RSpec.describe Events::Outbox do
  include ActiveJob::TestHelper

  let(:alice) { create(:user, name: "Alice") }
  let(:bob) { create(:user, name: "Bob Builder", email_address: "bob@example.com") }
  let(:project) { create(:project, owner: alice, name: "Website") }

  around do |example|
    original = Rails.configuration.x.events.sns_topic_arn
    Rails.configuration.x.events.sns_topic_arn = "arn:aws:sns:us-east-1:123456789012:task-api-events"
    example.run
  ensure
    Rails.configuration.x.events.sns_topic_arn = original
  end

  # Setting the scene is not what is under test: start each example with an empty outbox.
  before do
    create(:membership, project: project, user: bob)
    OutboxEvent.delete_all
  end

  def events(type = nil) = OutboxEvent.order(:id).then { |scope| type ? scope.where(event_type: type) : scope }

  describe "writing in the transaction of the change" do
    it "stores a finished envelope for each event, with what the change looked like" do
      Current.session = Session.new(user: alice)
      task = create(:task, project: project, title: "Ship it")

      stored = events("task.created").sole
      expect(stored.payload).to include(
        "specversion" => "1.0", "source" => "task-api", "type" => "task.created",
        "subject" => task.to_global_id.to_s, "projectid" => project.id, "id" => stored.event_id
      )
      expect(stored.payload["data"]).to include("id" => task.id, "title" => "Ship it")
      expect(stored.published_at).to be_nil
    end

    it "commits and rolls back with the change: no change without its event, no event without its change" do
      Task.transaction do
        create(:task, project: project)
        raise ActiveRecord::Rollback
      end

      expect(Task.count).to eq(0)
      expect(OutboxEvent.count).to eq(0)

      create(:task, project: project)
      expect(OutboxEvent.count).to eq(1)
    end

    it "is atomic with the change even when the failure comes after the event was written" do
      expect {
        Task.transaction do
          create(:task, project: project)
          raise "the process died before commit"
        end
      }.to raise_error("the process died before commit")

      expect(OutboxEvent.count).to eq(0)
    end

    it "records every event of a save once: an update that completes a task is task.updated and task.completed" do
      task = create(:task, project: project)
      OutboxEvent.delete_all

      task.update!(status: :done, title: "Done")

      expect(events.pluck(:event_type)).to contain_exactly("task.updated", "task.completed")
    end

    it "covers projects, comments, and soft deletes and restores" do
      other = create(:project, owner: alice)
      task = create(:task, project: other)
      create(:comment, task: task, user: alice)
      task.discard
      task.undiscard

      expect(events.pluck(:event_type)).to include("project.created", "task.created", "comment.created", "task.discarded", "task.restored")
    end

    it "snapshots the data as it was, not as it later became" do
      task = create(:task, project: project, title: "First title")
      task.update!(title: "Second title")

      created = events("task.created").sole
      expect(created.payload.dig("data", "title")).to eq("First title")
      expect(events("task.updated").sole.payload.dig("data", "title")).to eq("Second title")
    end

    it "includes tags and attachments saved with the record" do
      task = build(:task, project: project, tag_names: %w[bug api])
      task.attachments.attach(io: StringIO.new("hello"), filename: "note.txt", content_type: "text/plain")
      task.save!

      data = events("task.created").sole.payload["data"]
      expect(data["tags"]).to eq(%w[api bug])
      expect(data["attachments"].sole).to include("filename" => "note.txt", "byte_size" => 5)
    end

    it "does not record events other services have no use for" do
      described_class.record("webhook.delivered", subject: project, project_id: project.id)
      described_class.record("ai.completed", subject: project, project_id: project.id)

      expect(OutboxEvent.count).to eq(0)
    end

    it "wakes the relay once the transaction has committed, and not when it rolled back" do
      expect {
        Task.transaction do
          create(:task, project: project)
          raise ActiveRecord::Rollback
        end
      }.not_to have_enqueued_job(OutboxRelayJob)

      expect { create(:task, project: project) }.to have_enqueued_job(OutboxRelayJob).at_least(:once)
    end

    it "does nothing when no topic is configured, so a single-host install writes no rows" do
      Rails.configuration.x.events.sns_topic_arn = nil

      create(:task, project: project)

      expect(OutboxEvent.count).to eq(0)
      expect(described_class).not_to be_enabled
    end
  end

  describe "assignment" do
    it "records task.assigned when someone else is assigned, with who, to whom and where, as it was then" do
      task = create(:task, project: project, title: "Review the PR")
      OutboxEvent.delete_all
      Current.session = Session.new(user: alice)

      task.update!(assignee: bob)
      task.update!(assignee: alice) # later: the stored event must still say Bob

      assigned = events("task.assigned").sole.payload["data"]
      expect(assigned["recipient"]).to eq("id" => bob.id, "name" => "Bob Builder", "email_address" => "bob@example.com", "email_enabled" => true)
      expect(assigned["actor"]).to eq("id" => alice.id, "name" => "Alice")
      expect(assigned["project"]).to eq("id" => project.id, "name" => "Website")
      expect(assigned["task"]).to include("title" => "Review the PR")
      expect(assigned["url"]).to eq("#{Rails.configuration.x.frontend_url}/projects/#{project.id}/tasks/#{task.id}")
    end

    it "does not announce self-assignment, and rolls back with the assignment" do
      Current.session = Session.new(user: alice)
      create(:task, project: project, assignee: alice, creator: alice)
      expect(events("task.assigned")).to be_empty

      Task.transaction do
        create(:task, project: project, assignee: bob)
        raise ActiveRecord::Rollback
      end
      expect(events("task.assigned")).to be_empty
    end
  end

  describe "reminders" do
    it "records one task.due_soon per task and due date, however often the job runs" do
      due = create(:task, project: project, assignee: bob, due_on: Date.tomorrow)
      create(:task, project: project, assignee: bob, due_on: Date.tomorrow, status: :done)
      OutboxEvent.delete_all

      3.times { DueSoonRemindersJob.perform_now }

      stored = events("task.due_soon").sole
      expect(stored.payload["subject"]).to eq(due.to_global_id.to_s)
      expect(stored.payload.dig("data", "recipient", "email_address")).to eq("bob@example.com")
    end

    it "records a new reminder when the due date moves" do
      task = create(:task, project: project, assignee: bob, due_on: Date.tomorrow)
      OutboxEvent.delete_all
      DueSoonRemindersJob.perform_now
      task.update!(due_on: Date.tomorrow + 1)

      travel(1.day) { DueSoonRemindersJob.perform_now }

      expect(events("task.due_soon").count).to eq(2)
    end
  end

  describe "waking the relay" do
    it "never lets a failure to enqueue reach the caller: the row is committed and the sweep finds it" do
      allow(OutboxRelayJob).to receive(:perform_later).and_raise(StandardError, "queue database is down")

      expect { create(:task, project: project) }.not_to raise_error
      expect(OutboxEvent.count).to be >= 1
    end
  end
end
