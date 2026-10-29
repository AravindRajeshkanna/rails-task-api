require "rails_helper"

RSpec.describe Webhooks::Deliverer do
  let(:webhook) { create(:webhook, url: "https://hooks.example.com/in") }
  let(:delivery) { create(:webhook_delivery, webhook:, event: "task.completed", payload: { "event" => "task.completed", "data" => { "id" => 7 } }) }

  before { stub_dns("hooks.example.com" => "203.0.113.10") }

  def deliver = described_class.new(delivery).call

  it "POSTs the JSON payload with identifying and signature headers, then records success" do
    stub = stub_request(:post, "https://hooks.example.com/in").to_return(status: 204)

    freeze_time do
      deliver

      expected_signature = OpenSSL::HMAC.hexdigest("SHA256", webhook.secret, "#{Time.current.to_i}.#{delivery.payload.to_json}")
      expect(stub.with(
        body: delivery.payload.to_json,
        headers: {
          "Content-Type" => "application/json",
          "User-Agent" => "TaskApi-Webhooks/1.0",
          "X-TaskApi-Event" => "task.completed",
          "X-TaskApi-Delivery" => delivery.id.to_s,
          "X-TaskApi-Timestamp" => Time.current.to_i.to_s,
          "X-TaskApi-Signature" => "sha256=#{expected_signature}"
        }
      )).to have_been_requested
    end

    expect(delivery.reload).to have_attributes(response_status: 204, error: nil, status: "delivered")
    expect(delivery.duration_ms).to be >= 0
  end

  it "connects to the IP it vetted, not to whatever DNS says later" do
    stub_request(:post, "https://hooks.example.com/in").to_return(status: 200)
    allow_any_instance_of(Net::HTTP).to receive(:ipaddr=).and_call_original

    deliver

    expect(Resolv).to have_received(:getaddresses).with("hooks.example.com").once
  end

  it "raises DeliveryFailed for non-2xx responses so the job retries, and records why" do
    stub_request(:post, "https://hooks.example.com/in").to_return(status: 502)

    expect { deliver }.to raise_error(described_class::DeliveryFailed, "HTTP 502")

    expect(delivery.reload).to have_attributes(response_status: 502, delivered_at: nil, status: "failed")
    expect(delivery.error).to eq("Receiver responded with HTTP 502")
  end

  it "treats timeouts and connection errors as retryable" do
    stub_request(:post, "https://hooks.example.com/in").to_timeout

    expect { deliver }.to raise_error(described_class::DeliveryFailed)
    expect(delivery.reload.error).to match(/Timeout/i)

    stub_request(:post, "https://hooks.example.com/in").to_raise(Errno::ECONNREFUSED)
    expect { deliver }.to raise_error(described_class::DeliveryFailed)
    expect(delivery.reload.error).to include("ECONNREFUSED")
  end

  it "records blocked addresses as permanent failures without making a request or raising" do
    stub_dns("hooks.example.com" => "169.254.169.254")

    expect { deliver }.not_to raise_error

    expect(a_request(:any, /.*/)).not_to have_been_made
    expect(delivery.reload.error).to start_with("Blocked:")
    expect(delivery.delivered_at).to be_nil
  end
end
