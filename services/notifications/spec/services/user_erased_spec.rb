require "rails_helper"

# What the delivery log does when the Task API says a person is erased (ADR 79).
RSpec.describe Notifications::Handlers::UserErased do
  let(:router) { Notifications::Router.new }
  let(:ada_uid) { "4d9a4e8e-5f35-4a27-9d44-5c4ee3f1a111" }

  def erased(data, id: SecureRandom.uuid) = cloud_event("user.erased", id: id, data: data, subject: "gid://task-api/User/2")

  def deliver_to(id, address: "ada@example.com", event: assigned_event(email: address))
    event["data"]["recipient"]["id"] = id
    router.dispatch(event)
  end

  describe "keeping the id of a recipient" do
    it "records the id the event carries next to the address, for a task event and for a password reset alike" do
      router.dispatch(assigned_event(email: "bob@example.com")) # recipient id 2: the Task API's user id
      router.dispatch(cloud_event("user.password_reset_requested", data: { "recipient" => { "id" => ada_uid, "name" => "Ada", "email_address" => "ada@example.com" }, "reset_url" => "https://app.example.com/reset/x" }))

      expect(Delivery.order(:id).pluck(:recipient, :recipient_id)).to eq([ [ "bob@example.com", "2" ], [ "ada@example.com", ada_uid ] ])
    end

    it "keeps none for the Slack post, which is not a person's" do
      allow(Rails.configuration.x).to receive_messages(slack_webhook_url: "https://hooks.slack.test/x", slack_events: [ "task.completed" ])
      allow(Notifications::Slack).to receive(:post)

      router.dispatch(cloud_event("task.completed", data: { "title" => "Done" }))

      expect(Delivery.sole).to have_attributes(channel: "slack", recipient: "webhook", recipient_id: nil)
    end
  end

  describe "forgetting a person" do
    before do
      deliver_to(2)
      deliver_to(2)
      deliver_to(3, address: "grace@example.com")
      router.dispatch(cloud_event("user.password_reset_requested", data: { "recipient" => { "id" => ada_uid, "email_address" => "ada@example.com" }, "reset_url" => "https://app.example.com/r" }))
    end

    it "deletes the rows of the Task API's user id and of the Auth service's uid, and only those" do
      expect(router.dispatch(erased({ "user_id" => 2, "auth_subject" => ada_uid }))).to eq(:handled)

      expect(Delivery.pluck(:recipient, :recipient_id)).to eq([ [ "grace@example.com", "3" ] ])
    end

    it "deletes by the user id when the person was never in the Auth service, and by the uid when only that is known" do
      router.dispatch(erased({ "user_id" => 2 }))
      expect(Delivery.pluck(:recipient_id)).to contain_exactly("3", ada_uid)

      router.dispatch(erased({ "auth_subject" => ada_uid }))
      expect(Delivery.pluck(:recipient_id)).to eq([ "3" ])
    end

    it "does not take another person's rows because they share an address: it is the id that identifies, as it is the id that is erased" do
      deliver_to(9, address: "ada@example.com")

      router.dispatch(erased({ "user_id" => 2, "auth_subject" => ada_uid }))

      expect(Delivery.where(recipient: "ada@example.com").pluck(:recipient_id)).to eq([ "9" ])
    end

    it "cannot find a row from before the id was recorded, which waits for the 90 days: said here so that it is not forgotten" do
      Delivery.create!(event_id: "old", event_type: "task.assigned", channel: "email", recipient: "ada@example.com", recipient_id: nil, created_at: 10.days.ago)

      router.dispatch(erased({ "user_id" => 2, "auth_subject" => ada_uid }))

      expect(Delivery.where(event_id: "old")).to exist
    end

    it "does nothing for somebody who received nothing, or for an event that names nobody, and the same event twice is dropped" do
      expect { router.dispatch(erased({ "user_id" => 999 })) }.not_to change(Delivery, :count)
      expect { router.dispatch(erased({})) }.not_to change(Delivery, :count)

      event = erased({ "user_id" => 3 }, id: "evt-once")
      router.dispatch(event)
      expect(router.dispatch(event)).to eq(:duplicate)
      expect(ProcessedEvent.where(event_id: "evt-once").count).to eq(1)
    end

    it "counts what it deleted" do
      expect { router.dispatch(erased({ "user_id" => 2 })) }.to change { Notifications::Metrics::ERASED_DELIVERIES.get }.by(2)
    end

    it "is deleted with the event's own record, so a failure leaves both for the retry" do
      allow(Delivery).to receive(:where).and_raise(ActiveRecord::StatementInvalid, "boom")

      expect { router.dispatch(erased({ "user_id" => 2 }, id: "evt-fails")) }.to raise_error(ActiveRecord::StatementInvalid)

      expect(ProcessedEvent.where(event_id: "evt-fails")).not_to exist
    end
  end
end
