require "rails_helper"

RSpec.describe "Events published for other services" do
  let(:alice) { create(:user) }
  let(:bob) { create(:user, name: "Bob Builder", email_address: "bob@example.com") }
  let(:project) { create(:project, owner: alice, name: "Website") }

  before { create(:membership, project: project, user: bob) }

  def event_for(name, subject, **payload)
    { name: name, payload: { subject: subject.to_global_id.to_s, project_id: project.id }.merge(payload), context: {}, tags: {}, timestamp: Time.utc(2026, 10, 29, 12).to_i * 1_000_000_000 }
  end

  describe Events::CloudEvent do
    it "wraps a resource event in a CloudEvents 1.0 envelope" do
      task = create(:task, project: project, title: "Ship it")

      envelope = described_class.build(event_for("task.completed", task), id: "evt-1")

      expect(envelope).to include(
        specversion: "1.0", id: "evt-1", source: "task-api", type: "task.completed", time: "2026-10-29T12:00:00.000Z",
        datacontenttype: "application/json", subject: "gid://task-api/Task/#{task.id}", projectid: project.id
      )
      expect(envelope[:data]).to include("id" => task.id, "title" => "Ship it")
    end

    it "enriches notification events so consumers never call back" do
      task = create(:task, project: project, title: "Review the PR", assignee: bob)

      data = described_class.build(event_for("task.assigned", task, actor_id: alice.id))[:data]

      expect(data[:recipient]).to eq(id: bob.id, name: "Bob Builder", email_address: "bob@example.com")
      expect(data[:project]).to eq(id: project.id, name: "Website")
      expect(data[:actor]).to eq(id: alice.id, name: alice.name)
      expect(data[:task]).to include("title" => "Review the PR")
      expect(data[:url]).to eq("#{Rails.configuration.x.frontend_url}/projects/#{project.id}/tasks/#{task.id}")
    end

    it "gives up on events whose subject was deleted" do
      task = create(:task, project: project)
      event = event_for("task.updated", task)
      task.destroy

      expect(described_class.build(event)).to be_nil
    end
  end

  describe Events::SnsPublisher do
    let(:sns) { Aws::SNS::Client.new(stub_responses: true, region: "us-east-1") }
    let(:envelope) { { specversion: "1.0", id: "evt-1", source: "task-api", type: "task.assigned", projectid: 7, data: {} } }

    around do |example|
      original = Rails.configuration.x.events.sns_topic_arn
      Rails.configuration.x.events.sns_topic_arn = "arn:aws:sns:us-east-1:123456789012:task-api-events"
      described_class.client = sns
      example.run
    ensure
      Rails.configuration.x.events.sns_topic_arn = original
      described_class.client = nil
    end

    it "publishes the envelope with attributes subscriptions can filter on" do
      described_class.publish(envelope)

      params = sns.api_requests.last[:params]
      expect(params[:topic_arn]).to eq("arn:aws:sns:us-east-1:123456789012:task-api-events")
      expect(JSON.parse(params[:message])).to include("id" => "evt-1", "type" => "task.assigned")
      expect(params[:message_attributes]).to eq(
        "type" => { data_type: "String", string_value: "task.assigned" },
        "source" => { data_type: "String", string_value: "task-api" },
        "project_id" => { data_type: "Number", string_value: "7" }
      )
    end

    it "treats throttling as retryable and anything else as a real failure" do
      sns.stub_responses(:publish, "ThrottledException")
      expect { described_class.publish(envelope) }.to raise_error(described_class::Retryable)

      sns.stub_responses(:publish, "AuthorizationErrorException")
      expect { described_class.publish(envelope) }.to raise_error(Aws::SNS::Errors::AuthorizationErrorException)
    end

    it "refuses to run without a topic" do
      Rails.configuration.x.events.sns_topic_arn = nil

      expect { described_class.publish(envelope) }.to raise_error(described_class::NotConfigured)
    end

    it "is driven by a job that retries throttling but drops misconfiguration" do
      sns.stub_responses(:publish, "ThrottledException")
      expect { PublishEventJob.perform_now(envelope) }.to have_enqueued_job(PublishEventJob)

      Rails.configuration.x.events.sns_topic_arn = nil
      expect { PublishEventJob.perform_now(envelope) }.not_to raise_error
    end
  end

  describe Events::SnsSubscriber do
    it "queues one publish job per event" do
      task = create(:task, project: project)

      expect { described_class.new.emit(event_for("task.created", task)) }.to have_enqueued_job(PublishEventJob).with(hash_including(type: "task.created"))
    end
  end

  describe "emission" do
    it "emits task.assigned when someone else is assigned, and still mails in local mode" do
      task = create(:task, project: project)
      Current.session = Session.new(user: alice)

      events = record_events { task.update!(assignee: bob) }

      expect(events.payloads("task.assigned").sole).to include(project_id: project.id, actor_id: alice.id)
      expect(enqueued_jobs.map { |job| job["job_class"] }).to include("ActionMailer::MailDeliveryJob")
    end

    it "leaves the email to the Notification service in remote mode" do
      Rails.configuration.x.notifications.mode = "remote"
      task = create(:task, project: project)
      Current.session = Session.new(user: alice)

      events = record_events { task.update!(assignee: bob) }

      expect(events.names).to include("task.assigned")
      expect(enqueued_jobs.map { |job| job["job_class"] }).not_to include("ActionMailer::MailDeliveryJob")
    ensure
      Rails.configuration.x.notifications.mode = "local"
    end

    it "does not announce self-assignment" do
      Current.session = Session.new(user: alice)
      events = record_events { create(:task, project: project, assignee: alice, creator: alice) }

      expect(events.names).not_to include("task.assigned")
    end

    it "emits task.due_soon for tomorrow's open tasks" do
      due = create(:task, project: project, assignee: bob, due_on: Date.tomorrow)
      create(:task, project: project, assignee: bob, due_on: Date.tomorrow, status: :done)

      events = record_events { DueSoonRemindersJob.perform_now }

      expect(events.payloads("task.due_soon").sole).to include(subject: due.to_global_id.to_s)
    end
  end
end

RSpec.describe EventPayload do
  it "returns nil for a subject deleted since the event was emitted" do
    task = create(:task)
    event = { name: "task.updated", payload: { subject: task.to_global_id.to_s }, timestamp: 0 }
    task.destroy

    expect(described_class.build(event)).to be_nil
  end
end
