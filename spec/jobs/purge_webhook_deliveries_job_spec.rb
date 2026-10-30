require "rails_helper"

RSpec.describe PurgeWebhookDeliveriesJob do
  let(:webhook) { create(:webhook, project: create(:project, owner: create(:user))) }

  def delivery(age) = webhook.deliveries.create!(event: "task.created", payload: { data: { title: "Land on the moon" } }, created_at: age.ago)

  it "removes deliveries older than a month, with the task text they carried, and nothing newer" do
    old = delivery(31.days)
    recent = delivery(29.days)

    described_class.perform_now

    expect(WebhookDelivery.pluck(:id)).to contain_exactly(recent.id)
    expect(WebhookDelivery.exists?(old.id)).to be(false)
  end

  it "works through a backlog in batches" do
    stub_const("PurgeWebhookDeliveriesJob", Class.new(described_class) { def perform = WebhookDelivery.expired.in_batches(of: 2).delete_all })
    5.times { delivery(60.days) }
    keep = delivery(1.day)

    PurgeWebhookDeliveriesJob.perform_now

    expect(WebhookDelivery.pluck(:id)).to eq([ keep.id ])
  end

  it "is scheduled every day" do
    schedule = YAML.load_file(Rails.root.join("config/recurring.yml")).dig("production", "prune_webhook_deliveries")

    expect(schedule).to include("class" => "PurgeWebhookDeliveriesJob", "schedule" => "every day at 4:20am")
  end
end
