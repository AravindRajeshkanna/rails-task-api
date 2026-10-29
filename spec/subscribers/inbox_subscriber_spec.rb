require "rails_helper"

RSpec.describe Events::InboxSubscriber do
  let(:owner) { create(:user, name: "Olive") }
  let(:ada) { create(:user, name: "Ada") }
  let(:grace) { create(:user, name: "Grace") }
  let!(:project) { create(:project, owner: owner, name: "Apollo") }

  before do
    create(:membership, project: project, user: ada)
    create(:membership, project: project, user: grace)
  end

  def inbox(user) = Notification.where(user: user).order(:id)

  # Runs the block as +user+, the way a request would, and forgets what setting the scene notified.
  def acting_as(user)
    Current.session = Session.start_for!(user).first
    yield
  ensure
    Current.reset
  end

  def fresh_start = Notification.delete_all

  describe "assignment" do
    it "tells the new assignee, with what they need to find the task, and not the person who assigned it" do
      task = create(:task, project: project, creator: owner, title: "Land on the moon")

      acting_as(owner) { task.update!(assignee: ada) }

      notification = inbox(ada).sole
      expect(notification).to have_attributes(kind: "task.assigned", task_id: task.id, project_id: project.id, actor_id: owner.id)
      expect(notification.data).to eq("task_title" => "Land on the moon", "project_name" => "Apollo")
      expect(inbox(owner)).to be_empty
    end

    it "does not tell people about assigning a task to themselves" do
      task = create(:task, project: project, creator: owner)

      acting_as(ada) { task.update!(assignee: ada) }

      expect(Notification.count).to eq(0)
    end

    it "tells each new assignee, every time" do
      task = create(:task, project: project, creator: owner)

      acting_as(owner) { task.update!(assignee: ada) }
      acting_as(owner) { task.update!(assignee: grace) }
      acting_as(owner) { task.update!(assignee: ada) }

      expect(inbox(ada).count).to eq(2)
      expect(inbox(grace).count).to eq(1)
    end
  end

  describe "due reminders" do
    it "tells the assignee once per task and day, however often the job runs" do
      task = create(:task, project: project, creator: owner, assignee: ada, due_on: Date.tomorrow)
      fresh_start

      2.times { DueSoonRemindersJob.perform_now }

      expect(inbox(ada).sole).to have_attributes(kind: "task.due_soon", task_id: task.id, actor_id: nil)
      expect(inbox(ada).sole.data).to include("due_on" => Date.tomorrow.iso8601)
    end

    it "tells again for a new due date" do
      task = create(:task, project: project, creator: owner, assignee: ada, due_on: Date.tomorrow)
      fresh_start
      DueSoonRemindersJob.perform_now
      task.update!(due_on: Date.tomorrow + 1)

      travel(1.day) { DueSoonRemindersJob.perform_now }

      expect(inbox(ada).count).to eq(2)
    end
  end

  describe "comments" do
    let!(:task) { create(:task, project: project, creator: owner, assignee: ada, title: "Land on the moon") }

    before { fresh_start }

    it "tells the assignee and the creator, but not the commenter" do
      acting_as(grace) { create(:comment, task: task, user: grace, body: "  Looks   good\nto me ") }

      expect(inbox(ada).sole).to have_attributes(kind: "comment.created", actor_id: grace.id)
      expect(inbox(owner).sole.data).to include("comment_excerpt" => "Looks good to me", "task_title" => "Land on the moon")
      expect(inbox(grace)).to be_empty
    end

    it "tells nobody twice when the creator is also the assignee, and nobody about their own comment" do
      mine = create(:task, project: project, creator: ada, assignee: ada)
      fresh_start

      create(:comment, task: mine, user: ada)
      expect(inbox(ada)).to be_empty

      create(:comment, task: mine, user: grace)
      expect(inbox(ada).count).to eq(1)
    end

    it "clips a long comment" do
      create(:comment, task: task, user: grace, body: "word " * 100)

      expect(inbox(ada).sole.data["comment_excerpt"].length).to be <= Events::InboxSubscriber::EXCERPT
    end
  end

  describe "completion" do
    it "tells the creator when someone else completes the task" do
      task = create(:task, project: project, creator: owner, assignee: ada)
      fresh_start

      acting_as(ada) { task.update!(status: :done) }

      expect(inbox(owner).sole).to have_attributes(kind: "task.completed", actor_id: ada.id)
    end

    it "does not tell people about finishing their own tasks" do
      task = create(:task, project: project, creator: owner, assignee: ada)
      fresh_start

      acting_as(owner) { task.update!(status: :done) }

      expect(inbox(owner)).to be_empty
    end
  end

  describe "who may hear" do
    it "tells nobody about a project they have left, or one that is archived" do
      task = create(:task, project: project, creator: owner, assignee: ada)
      Membership.find_by!(project: project, user: ada).destroy!
      fresh_start

      create(:comment, task: task, user: grace)
      expect(inbox(ada)).to be_empty # left the project
      expect(inbox(owner).count).to eq(1) # still in it

      fresh_start
      project.update!(discarded_at: Time.current)
      create(:comment, task: task, user: grace)
      expect(Notification.count).to eq(0) # archived
    end

    it "does not tell about a discarded task" do
      task = create(:task, project: project, creator: owner, assignee: ada)
      task.update!(discarded_at: Time.current)
      fresh_start

      create(:comment, task: task, user: grace)

      expect(Notification.count).to eq(0)
    end

    it "works in either notification mode, because email is separate" do
      allow(Rails.configuration.x.notifications).to receive(:mode).and_return("remote")
      task = create(:task, project: project, creator: owner)

      acting_as(owner) { task.update!(assignee: ada) }

      expect(inbox(ada).count).to eq(1)
    end
  end
end
