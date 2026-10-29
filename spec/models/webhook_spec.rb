require "rails_helper"

RSpec.describe Webhook do
  subject(:webhook) { build(:webhook) }

  it { is_expected.to belong_to(:project) }
  it { is_expected.to have_many(:deliveries).class_name("WebhookDelivery").dependent(:destroy) }
  it { is_expected.to validate_presence_of(:url) }

  describe "url" do
    it "accepts https" do
      expect(build(:webhook, url: "https://example.com/hook")).to be_valid
    end

    it "rejects garbage and non-http schemes" do
      expect(build(:webhook, url: "not a url")).not_to be_valid
      expect(build(:webhook, url: "ftp://example.com/hook")).not_to be_valid
      expect(build(:webhook, url: "javascript:alert(1)")).not_to be_valid
    end

    it "requires https in production" do
      allow(Rails.env).to receive(:production?).and_return(true)

      expect(build(:webhook, url: "http://example.com/hook")).not_to be_valid
      expect(build(:webhook, url: "https://example.com/hook")).to be_valid
    end
  end

  describe "events" do
    it "accepts known events" do
      expect(build(:webhook, events: %w[task.created comment.created])).to be_valid
    end

    it "rejects unknown events" do
      webhook = build(:webhook, events: %w[task.created user.exploded])

      expect(webhook).not_to be_valid
      expect(webhook.errors[:events].first).to include("user.exploded")
    end
  end

  describe "secret" do
    it "is generated on create and encrypted at rest" do
      webhook = create(:webhook)

      expect(webhook.secret).to match(/\A\h{64}\z/)
      raw = ActiveRecord::Base.connection.select_value("SELECT secret FROM webhooks WHERE id = #{webhook.id}")
      expect(raw).not_to include(webhook.secret)
      expect(Webhook.find(webhook.id).secret).to eq(webhook.secret)
    end
  end

  describe ".listening_to" do
    let!(:everything) { create(:webhook, events: []) }
    let!(:completions) { create(:webhook, events: %w[task.completed]) }
    let!(:comments) { create(:webhook, events: %w[comment.created]) }

    it "matches webhooks subscribed to the event or to everything" do
      expect(Webhook.listening_to("task.completed")).to contain_exactly(everything, completions)
      expect(Webhook.listening_to("comment.created")).to contain_exactly(everything, comments)
    end
  end
end
