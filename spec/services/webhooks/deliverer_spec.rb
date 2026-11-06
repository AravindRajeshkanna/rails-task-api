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

  describe "while a new secret is being rotated in (ADR 78)" do
    let(:sent) { [] }

    # What the receiver is sent, and what each of its two secrets would make of it: a receiver recomputes the HMAC of "<timestamp>.<body>" and compares.
    def delivered_with(secret_of_the_receiver)
      stub_request(:post, "https://hooks.example.com/in").to_return { |request| sent << request; { status: 204 } }
      freeze_time { deliver }
      request = sent.last
      timestamp = request.headers["X-Taskapi-Timestamp"]
      expected = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret_of_the_receiver, "#{timestamp}.#{request.body}")}"
      [ request.headers["X-Taskapi-Signature"] == expected, request.headers["X-Taskapi-Signature-Next"] == expected, request ]
    end

    it "sends no second signature when nothing is being rotated" do
      _, _, request = delivered_with(webhook.secret)

      expect(request.headers).not_to have_key("X-Taskapi-Signature-Next")
    end

    it "signs X-TaskApi-Signature with the current secret, as before, and X-TaskApi-Signature-Next with the new one" do
      current = webhook.secret
      new_secret = webhook.begin_secret_rotation!

      by_current = delivered_with(current)
      by_new = delivered_with(new_secret)

      expect(by_current.first(2)).to eq([ true, false ]) # a receiver that has done nothing: its secret verifies the header it always read
      expect(by_new.first(2)).to eq([ false, true ]) # a receiver that has the new secret can already check it
      expect(by_new.last.headers["X-Taskapi-Signature-Next"]).to match(/\Asha256=\h{64}\z/)
    end

    it "signs only with the new secret once it is promoted, and the old one verifies nothing any more" do
      old = webhook.secret
      new_secret = webhook.begin_secret_rotation!
      webhook.promote_next_secret

      with_new = delivered_with(new_secret)
      with_old = delivered_with(old)

      expect(with_new.first(2)).to eq([ true, false ])
      expect(with_old.first(2)).to eq([ false, false ])
      expect(with_new.last.headers).not_to have_key("X-Taskapi-Signature-Next")
    end

    it "is back to one signature, the old one, when the rotation is cancelled" do
      old = webhook.secret
      webhook.begin_secret_rotation!
      webhook.cancel_secret_rotation

      verified, _, request = delivered_with(old)

      expect(verified).to be(true)
      expect(request.headers).not_to have_key("X-Taskapi-Signature-Next")
    end

    it "signs each attempt with what is current at that attempt: a retry after the promotion carries the new secret" do
      new_secret = webhook.begin_secret_rotation!
      stub_request(:post, "https://hooks.example.com/in").to_return(status: 502)
      expect { deliver }.to raise_error(described_class::DeliveryFailed)

      webhook.promote_next_secret
      retry_delivery = WebhookDelivery.find(delivery.id) # the job loads the delivery again for every attempt
      stub_request(:post, "https://hooks.example.com/in").to_return { |request| sent << request; { status: 204 } }
      described_class.new(retry_delivery).call

      timestamp = sent.last.headers["X-Taskapi-Timestamp"]
      expect(sent.last.headers["X-Taskapi-Signature"]).to eq("sha256=#{OpenSSL::HMAC.hexdigest('SHA256', new_secret, "#{timestamp}.#{sent.last.body}")}")
    end
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
