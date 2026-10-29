require "rails_helper"

RSpec.describe "Event subscribers" do
  let(:project) { create(:project) }

  describe Events::LogSubscriber do
    it "writes one greppable line per event" do
      allow(Rails.logger).to receive(:info).and_call_original

      task = create(:task, project:)

      expect(Rails.logger).to have_received(:info)
        .with("event=task.created subject=#{task.to_global_id} project_id=#{project.id} actor_id=")
    end
  end

  describe Events::BroadcastSubscriber do
    it "broadcasts task events to the project stream" do
      expect { create(:task, project:, title: "Live!") }
        .to have_broadcasted_to(ProjectChannel.stream_name(project.id))
        .with(a_hash_including("event" => "task.created", "data" => a_hash_including("title" => "Live!")))
    end

    it "broadcasts comment events" do
      task = create(:task, project:)

      expect { create(:comment, task:, body: "hello") }
        .to have_broadcasted_to(ProjectChannel.stream_name(project.id))
        .with(a_hash_including("event" => "comment.created", "data" => a_hash_including("body" => "hello")))
    end

    it "does not broadcast to other projects' streams" do
      expect { create(:task, project:) }
        .not_to have_broadcasted_to(ProjectChannel.stream_name(create(:project).id))
    end

    it "does not broadcast when the transaction rolls back" do
      expect {
        ActiveRecord::Base.transaction do
          create(:task, project:)
          raise ActiveRecord::Rollback
        end
      }.not_to have_broadcasted_to(ProjectChannel.stream_name(project.id))
    end
  end

  describe Events::WebhookSubscriber do
    it "snapshots the payload at emit time so retries replay what happened" do
      webhook = create(:webhook, project:, events: %w[task.updated])
      task = create(:task, project:, title: "Before")

      task.update!(title: "After")
      task.update_column(:title, "Changed again before delivery")

      delivery = webhook.deliveries.sole
      expect(delivery.payload.dig("data", "title")).to eq("After")
      expect(WebhookDeliveryJob).to have_been_enqueued.with(delivery)
    end

    it "skips events whose subject has since been deleted" do
      webhook = create(:webhook, project:)
      task = create(:task, project:)
      webhook.deliveries.destroy_all
      allow(GlobalID::Locator).to receive(:locate).and_return(nil)

      expect { task.update!(title: "gone") }.not_to change(WebhookDelivery, :count)
    end
  end

  describe Events::Subscriber do
    it "re-raises in test so bugs surface" do
      subscriber = Class.new(described_class) { private def handle(_event) = raise("boom") }.new

      expect { subscriber.emit(name: "x") }.to raise_error("boom")
    end

    it "reports instead of raising outside the test environment" do
      subscriber = Class.new(described_class) { private def handle(_event) = raise("boom") }.new
      allow(Rails.env).to receive(:test?).and_return(false)
      allow(Rails.error).to receive(:report)

      expect { subscriber.emit(name: "task.created") }.not_to raise_error
      expect(Rails.error).to have_received(:report).with(an_instance_of(RuntimeError), hash_including(handled: true))
    end
  end
end
