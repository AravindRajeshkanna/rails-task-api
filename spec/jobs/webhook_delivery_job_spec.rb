require "rails_helper"

RSpec.describe WebhookDeliveryJob do
  let(:webhook) { create(:webhook, url: "https://hooks.example.com/in") }
  let(:delivery) { create(:webhook_delivery, webhook:) }

  before { stub_dns("hooks.example.com" => "203.0.113.10") }

  it "delivers" do
    stub_request(:post, "https://hooks.example.com/in").to_return(status: 200)

    described_class.perform_now(delivery)

    expect(delivery.reload.delivered_at).to be_present
  end

  it "does nothing for deliveries already made or webhooks switched off since" do
    delivery.update!(delivered_at: 1.minute.ago)
    described_class.perform_now(delivery)

    webhook.update!(active: false)
    other = create(:webhook_delivery, webhook:)
    described_class.perform_now(other)

    expect(a_request(:any, /.*/)).not_to have_been_made
  end

  it "retries failures with back-off, up to 6 attempts" do
    stub_request(:post, "https://hooks.example.com/in").to_return(status: 500)

    expect { described_class.perform_now(delivery) }.to have_enqueued_job(described_class).with(delivery).at(be > 1.second.from_now)
    expect(delivery.reload.error).to be_present
  end

  it "waits and tries again, without a request to the receiver, when KMS cannot unwrap the secret's key: the event must not be lost for that" do
    stub_request(:post, "https://hooks.example.com/in").to_return(status: 200)
    fresh = WebhookDelivery.find(delivery.id) # a job loads its delivery, and the webhook's secret, from the database
    KmsEncryption.cache.clear
    down = Class.new { def decrypt(**) = raise(KmsEncryption::Unavailable.new("ThrottlingException", reason: :throttled)) }.new
    allow(KmsEncryption.configuration).to receive(:client).and_return(down)

    expect { described_class.perform_now(fresh) }.to have_enqueued_job(described_class).with(delivery).at(be > 1.second.from_now)
    expect(a_request(:any, /.*/)).not_to have_been_made
    expect(delivery.reload.delivered_at).to be_nil
  end

  it "gives up after 6 attempts, leaving the failure in the log" do
    request = stub_request(:post, "https://hooks.example.com/in").to_return(status: 500)

    # ActiveJob::TestHelper wraps errors escaping an inline-performed job in Minitest::UnexpectedError.
    expect { perform_enqueued_jobs { described_class.perform_later(delivery) } }
      .to raise_error { |error| expect(error.error).to be_a(Webhooks::Deliverer::DeliveryFailed) }

    expect(request).to have_been_requested.times(6)
    expect(delivery.reload).to have_attributes(status: "failed", response_status: 500, delivered_at: nil)
  end

  it "succeeds on a later attempt if the receiver recovers" do
    stub_request(:post, "https://hooks.example.com/in").to_return({ status: 503 }, { status: 200 })

    perform_enqueued_jobs { described_class.perform_later(delivery) }

    expect(delivery.reload).to have_attributes(status: "delivered", response_status: 200, error: nil)
  end

  it "is discarded quietly if its delivery was deleted before it ran" do
    described_class.perform_later(delivery)
    delivery.destroy!

    expect { perform_enqueued_jobs }.not_to raise_error
    expect(a_request(:any, /.*/)).not_to have_been_made
  end
end
