require "rails_helper"

RSpec.describe Notifications::Router do
  subject(:router) { described_class.new }

  describe "task.assigned" do
    it "emails the assignee a message built from the event alone" do
      expect(router.dispatch(assigned_event(title: "Review the PR"))).to eq(:handled)

      mail = sent.sole
      expect(mail.to).to eq([ "bob@example.com" ])
      expect(mail.subject).to eq("You were assigned: Review the PR")
      expect(mail.body.to_s).to include("Alice Admin assigned you a task in Website", "Review the PR", "Due: 2026-11-03", "https://app.example.com/projects/3/tasks/7")
      expect(Delivery.sole).to have_attributes(channel: "email", recipient: "bob@example.com", event_type: "task.assigned")
    end

    it "keeps a hostile title to one line in the subject" do
      router.dispatch(assigned_event(title: "Hi\r\nBcc: attacker@evil.test\n\nBuy now"))

      expect(sent.sole.subject).not_to match(/[\r\n]/)
      expect(sent.sole.bcc).to be_nil
    end

    it "sends nothing, and still records the event, when the recipient muted it or takes a digest" do
      event = assigned_event(email_enabled: false)

      expect(router.dispatch(event)).to eq(:handled)
      expect(router.dispatch(event)).to eq(:duplicate)
      expect(sent).to be_empty
      expect(Delivery.count).to eq(0)
    end

    it "sends as before when the event says nothing about it, or says yes" do
      router.dispatch(assigned_event)
      router.dispatch(assigned_event(email_enabled: true))

      expect(sent.size).to eq(2)
    end

    it "refuses events without a valid recipient" do
      event = assigned_event(email: "not-an-email")

      expect { router.dispatch(event) }.to raise_error(Notifications::InvalidEvent, /recipient/)
      expect(sent).to be_empty
      expect(ProcessedEvent.count).to eq(0)
    end
  end

  describe "task.due_soon and user.password_reset_requested" do
    it "sends the reminder" do
      router.dispatch(cloud_event("task.due_soon", data: assigned_event["data"].merge("task" => { "title" => "File taxes", "due_on" => "2026-10-30" })))

      expect(sent.sole.subject).to eq("Due tomorrow: File taxes")
      expect(sent.sole.body.to_s).to include("is due tomorrow (2026-10-30)")
    end

    it "sends the reset link" do
      router.dispatch(cloud_event("user.password_reset_requested", source: "auth-service", data: {
        "recipient" => { "name" => "Pat", "email_address" => "pat@example.com" },
        "reset_url" => "https://app.example.com/reset-password?token=abc", "expires_in_minutes" => 15
      }))

      expect(sent.sole.to).to eq([ "pat@example.com" ])
      expect(sent.sole.body.to_s).to include("Hi Pat", "https://app.example.com/reset-password?token=abc", "15 minutes")
    end
  end

  describe "at-least-once delivery" do
    it "acts on an event once, however many times it arrives" do
      event = assigned_event(id: "evt-1")

      results = Array.new(3) { router.dispatch(event) }

      expect(results).to eq(%i[handled duplicate duplicate])
      expect(sent.size).to eq(1)
    end

    it "does not mark an event processed when its handler fails, so a retry can succeed" do
      event = assigned_event(id: "evt-2")
      allow_any_instance_of(ActionMailer::MessageDelivery).to receive(:deliver_now).and_raise(Net::SMTPServerBusy.new("busy"))

      expect { router.dispatch(event) }.to raise_error(Notifications::DeliveryError, /SMTP/)
      expect(ProcessedEvent.where(event_id: "evt-2")).to be_empty
      expect(Delivery.count).to eq(0)
    end
  end

  describe "other events" do
    it "ignores types nobody here handles" do
      expect(router.dispatch(cloud_event("project.created", data: {}))).to eq(:ignored)
      expect(ProcessedEvent.count).to eq(0)
    end

    {
      "not an object" => [ "oops" ],
      "wrong specversion" => [ { "specversion" => "0.3", "id" => "1", "type" => "x", "data" => {} } ],
      "no id" => [ { "specversion" => "1.0", "type" => "x", "data" => {} } ],
      "no data" => [ { "specversion" => "1.0", "id" => "1", "type" => "task.assigned" } ]
    }.each do |name, (event)|
      it "rejects an event with #{name}" do
        expect { router.dispatch(event) }.to raise_error(Notifications::InvalidEvent)
      end
    end
  end

  describe "Slack" do
    let(:completed) { cloud_event("task.completed", data: { "title" => "Ship v2" }) }

    around do |example|
      config = Rails.configuration.x
      original = config.slack_webhook_url
      config.slack_webhook_url = "https://hooks.slack.test/T/B/x"
      example.run
    ensure
      config.slack_webhook_url = original
    end

    it "announces completed tasks" do
      stub = stub_request(:post, "https://hooks.slack.test/T/B/x").with(body: { text: "Task completed: Ship v2 (project 3)" }.to_json).to_return(status: 200)

      router.dispatch(completed)

      expect(stub).to have_been_requested
      expect(Delivery.sole).to have_attributes(channel: "slack")
    end

    it "does nothing without a webhook URL" do
      Rails.configuration.x.slack_webhook_url = nil

      expect(router.dispatch(completed)).to eq(:handled)
      expect(Delivery.count).to eq(0)
    end

    it "treats a Slack outage as a delivery failure to retry" do
      stub_request(:post, "https://hooks.slack.test/T/B/x").to_return(status: 503)

      expect { router.dispatch(completed) }.to raise_error(Notifications::DeliveryError, /503/)
      expect(ProcessedEvent.count).to eq(0)
    end
  end
end
