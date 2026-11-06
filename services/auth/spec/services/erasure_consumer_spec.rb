require "rails_helper"

# The consumer that makes the Task API's `user.erased` (ADR 79) delete an identity. Shaped like the Notification service's, which this was copied from.
RSpec.describe AuthService::ErasureConsumer do
  let(:sqs) { Aws::SQS::Client.new(stub_responses: true, region: "us-east-1") }
  let(:queue_url) { "https://sqs.us-east-1.amazonaws.com/123456789012/auth-erasure" }
  let(:consumer) { described_class.new(queue_url: queue_url, client: sqs, wait_time: 0) }
  let!(:ada) { create(:user, email_address: "ada@example.com") }
  let(:subject_id) { ada.uid }

  def erased_event(id: "user.erased:41", data: { "user_id" => 41, "auth_subject" => subject_id }, type: "user.erased")
    { "specversion" => "1.0", "id" => id, "source" => "task-api", "type" => type, "time" => Time.current.iso8601, "datacontenttype" => "application/json", "data" => data }
  end

  def message(body, id: "m-#{SecureRandom.hex(3)}", received: "1")
    { message_id: id, receipt_handle: "rh-#{id}", body: body.is_a?(String) ? body : body.to_json, attributes: { "ApproximateReceiveCount" => received } }
  end

  def requests(operation) = sqs.api_requests.select { |request| request[:operation_name] == operation }.map { |request| request[:params] }

  def outcome(name) = AuthService::Metrics::ERASURES.get(labels: { outcome: name })

  it "deletes the identity the event names, and then the message" do
    sqs.stub_responses(:receive_message, messages: [ message(erased_event) ])

    expect { consumer.poll_once }.to change(User, :count).by(-1).and change { outcome("erased") }.by(1)

    expect(User.exists?(ada.id)).to be(false)
    expect(requests(:delete_message).sole).to include(queue_url: queue_url)
    expect(requests(:change_message_visibility)).to be_empty
    expect(requests(:receive_message).sole).to include(max_number_of_messages: 10, wait_time_seconds: 0)
  end

  it "understands SNS notifications as well as raw delivery" do
    wrapped = { "Type" => "Notification", "MessageId" => "x", "Message" => erased_event.to_json }
    sqs.stub_responses(:receive_message, messages: [ message(wrapped) ])

    consumer.poll_once

    expect(User.exists?(ada.id)).to be(false)
  end

  it "finds an imported account by the Task API's id when the event has no subject" do
    ada.update_columns(legacy_id: 41)
    sqs.stub_responses(:receive_message, messages: [ message(erased_event(data: { "user_id" => 41 })) ])

    consumer.poll_once

    expect(User.exists?(ada.id)).to be(false)
  end

  it "deletes the message of an event for somebody it never knew, or one it already handled, and counts it as unknown" do
    event = erased_event(data: { "user_id" => 99, "auth_subject" => SecureRandom.uuid })
    sqs.stub_responses(:receive_message, messages: [ message(event), message(event) ])

    expect { consumer.poll_once }.to change { outcome("unknown") }.by(2)

    expect(User.exists?(ada.id)).to be(true)
    expect(requests(:delete_message).size).to eq(2)
  end

  it "ignores the events it has no use for, deleting them, and deletes nothing" do
    sqs.stub_responses(:receive_message, messages: [ message(erased_event(type: "task.assigned")) ])

    expect { consumer.poll_once }.to change { outcome("ignored") }.by(1)

    expect(User.exists?(ada.id)).to be(true)
    expect(requests(:delete_message).size).to eq(1)
  end

  it "leaves a message it cannot act on on the queue, with a delay that grows, and deletes nothing" do
    [ "1", "2", "5", "20" ].each do |count|
      sqs.stub_responses(:receive_message, messages: [ message(erased_event(data: { "auth_subject" => "not-a-uid" }), received: count) ])
      consumer.poll_once
    end

    expect(requests(:delete_message)).to be_empty
    expect(requests(:change_message_visibility).map { |params| params[:visibility_timeout] }).to eq([ 30, 60, 480, 900 ])
    expect(User.exists?(ada.id)).to be(true)
  end

  it "does not delete poison messages: after maxReceiveCount SQS moves them to the dead-letter queue" do
    sqs.stub_responses(:receive_message, messages: [ message("{not json"), message({ "hello" => "world" }), message(erased_event(data: nil)), message(erased_event(data: { "user_id" => "41" })) ])

    expect { consumer.poll_once }.to change { outcome("failed") }.by(4)

    expect(requests(:delete_message)).to be_empty
    expect(requests(:change_message_visibility).size).to eq(4)
  end

  it "keeps the message when the database fails, so that the deletion is tried again" do
    allow(AuthService::Erasure).to receive(:call).and_raise(ActiveRecord::StatementInvalid, "boom")
    sqs.stub_responses(:receive_message, messages: [ message(erased_event) ])

    consumer.poll_once

    expect(requests(:delete_message)).to be_empty
    expect(requests(:change_message_visibility).size).to eq(1)
    expect(User.exists?(ada.id)).to be(true)
  end

  it "keeps polling through an AWS outage and reports it" do
    sqs.stub_responses(:receive_message, "InternalFailure")
    expect(Rails.error).to receive(:report).with(instance_of(Aws::SQS::Errors::InternalFailure), hash_including(handled: true))

    expect { consumer.poll_once }.not_to raise_error
    expect(described_class.last_poll_age).to be < 1
  end

  it "stops when asked" do
    sqs.stub_responses(:receive_message, ->(_context) { consumer.stop; { messages: [] } })

    Timeout.timeout(5) { consumer.run }

    expect(requests(:receive_message).size).to eq(1)
  end

  it "needs a queue" do
    expect { described_class.new(queue_url: nil, client: sqs) }.to raise_error(ArgumentError, /AUTH_ERASURE_QUEUE_URL/)
  end

  describe ".report_crash" do
    let(:error) { ArgumentError.new("boom").tap { |e| e.set_backtrace(Array.new(20) { |i| "app/x.rb:#{i}" }) } }

    it "writes what ended the consumer to the log, with the top of the backtrace, and tells Rails.error nobody handled it" do
      allow(Rails.logger).to receive(:error)
      allow(Rails.error).to receive(:report)

      described_class.report_crash(error)

      expect(Rails.logger).to have_received(:error).with(event: "auth.erasure_consumer_crashed", error: "ArgumentError", message: "boom", backtrace: Array.new(8) { |i| "app/x.rb:#{i}" })
      expect(Rails.error).to have_received(:report).with(error, handled: false, context: { consumer: "erasure" })
    end

    it "is what the Puma plugin calls before it stops the process, and the plugin is loaded only where the consumer is wanted" do
      plugin = Rails.root.join("lib/puma/plugin/auth_erasure_consumer.rb").read

      expect(plugin.index("AuthService::ErasureConsumer.report_crash(error)")).to be < plugin.index('Process.kill("TERM"')
      expect(Rails.root.join("config/puma.rb").read).to include('plugin :auth_erasure_consumer if ENV["AUTH_ERASURE_CONSUMER"] == "true"')
    end
  end

  it "reports its last poll to /metrics, or -1 while it is not running" do
    described_class.reset!
    AuthService::Metrics.collect!
    expect(AuthService::Metrics::POLL_AGE.get).to eq(-1)

    described_class.beat!
    AuthService::Metrics.collect!
    expect(AuthService::Metrics::POLL_AGE.get).to be_between(0, 1)
  end
end
