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

  describe "rotating the secret" do
    let!(:webhook) { create(:webhook) }

    it "is not under way for a webhook nobody has rotated" do
      expect(webhook).not_to be_rotating
      expect(webhook.next_secret).to be_nil
    end

    it "makes a new secret that is not the current one, and leaves the current one alone" do
      current = webhook.secret

      new_secret = webhook.begin_secret_rotation!

      expect(new_secret).to match(/\A\h{64}\z/)
      expect(new_secret).not_to eq(current)
      expect(webhook.reload).to be_rotating
      expect(webhook).to have_attributes(secret: current, next_secret: new_secret, rotation_started_at: be_within(5.seconds).of(Time.current))
    end

    it "replaces a new secret that is already there, which is how a lost one is made again" do
      first = webhook.begin_secret_rotation!
      second = webhook.begin_secret_rotation!

      expect(second).not_to eq(first)
      expect(webhook.reload.next_secret).to eq(second)
    end

    it "promotes: the new secret becomes the secret, the old one is gone, and nothing is rotating" do
      old = webhook.secret
      new_secret = webhook.begin_secret_rotation!

      expect(webhook.promote_next_secret).to be(true)

      expect(webhook.reload).to have_attributes(secret: new_secret, next_secret: nil, rotation_started_at: nil)
      expect(webhook).not_to be_rotating
      expect(webhook.secret).not_to eq(old)
    end

    it "cancels: the new secret is forgotten and the secret is as it was" do
      old = webhook.secret
      webhook.begin_secret_rotation!

      expect(webhook.cancel_secret_rotation).to be(true)

      expect(webhook.reload).to have_attributes(secret: old, next_secret: nil, rotation_started_at: nil)
    end

    it "does nothing, and says so, when nothing is being rotated in" do
      old = webhook.secret

      expect(webhook.promote_next_secret).to be(false)
      expect(webhook.cancel_secret_rotation).to be(false)
      expect(webhook.reload.secret).to eq(old)
    end

    it "promotes once when two admins press the button together: the second finds the first one's work" do
      new_secret = webhook.begin_secret_rotation!
      second = Webhook.find(webhook.id) # another process, loaded before the first one promoted

      results = [ webhook.promote_next_secret, second.promote_next_secret ]

      expect(results).to eq([ true, false ])
      expect(webhook.reload.secret).to eq(new_secret)
    end

    it "cannot be left half done: the database refuses a new secret with no start, and a start with no secret" do
      # Each in a savepoint: a violation aborts the transaction the example runs in.
      expect { Webhook.transaction(requires_new: true) { webhook.update_columns(rotation_started_at: Time.current) } }.to raise_error(ActiveRecord::CheckViolation, /webhooks_rotation_consistent/)
      expect { Webhook.transaction(requires_new: true) { Webhook.where(id: webhook.id).update_all(next_secret: "x") } }.to raise_error(ActiveRecord::CheckViolation, /webhooks_rotation_consistent/)
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
