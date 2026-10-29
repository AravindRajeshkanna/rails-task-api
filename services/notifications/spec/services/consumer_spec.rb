require "rails_helper"

RSpec.describe Notifications::Consumer do
  let(:sqs) { Aws::SQS::Client.new(stub_responses: true, region: "us-east-1") }
  let(:queue_url) { "https://sqs.us-east-1.amazonaws.com/123456789012/notifications" }
  let(:consumer) { described_class.new(queue_url: queue_url, client: sqs, wait_time: 0) }

  def message(body, id: "m-#{SecureRandom.hex(3)}", received: "1")
    { message_id: id, receipt_handle: "rh-#{id}", body: body.is_a?(String) ? body : body.to_json, attributes: { "ApproximateReceiveCount" => received } }
  end

  def requests(operation) = sqs.api_requests.select { |request| request[:operation_name] == operation }.map { |request| request[:params] }

  it "handles a message and deletes it" do
    sqs.stub_responses(:receive_message, messages: [ message(assigned_event) ])

    consumer.poll_once

    expect(sent.size).to eq(1)
    expect(requests(:delete_message).sole).to include(queue_url: queue_url)
    expect(requests(:change_message_visibility)).to be_empty
    expect(requests(:receive_message).sole).to include(max_number_of_messages: 10, wait_time_seconds: 0)
  end

  it "understands SNS notifications as well as raw delivery" do
    wrapped = { "Type" => "Notification", "MessageId" => "x", "Message" => assigned_event.to_json }
    sqs.stub_responses(:receive_message, messages: [ message(wrapped) ])

    consumer.poll_once

    expect(sent.size).to eq(1)
    expect(requests(:delete_message).size).to eq(1)
  end

  it "deletes duplicates and ignored events without acting" do
    event = assigned_event(id: "evt-dup")
    Notifications::Router.new.dispatch(event)
    sent.clear
    sqs.stub_responses(:receive_message, messages: [ message(event), message(cloud_event("project.created", data: {})) ])

    consumer.poll_once

    expect(sent).to be_empty
    expect(requests(:delete_message).size).to eq(2)
  end

  it "leaves a failing message on the queue and delays its retry, longer each time" do
    allow_any_instance_of(ActionMailer::MessageDelivery).to receive(:deliver_now).and_raise(Net::SMTPServerBusy.new("busy"))

    [ "1", "2", "5", "20" ].each do |count|
      sqs.stub_responses(:receive_message, messages: [ message(assigned_event, received: count) ])
      consumer.poll_once
    end

    expect(requests(:delete_message)).to be_empty
    expect(requests(:change_message_visibility).map { |params| params[:visibility_timeout] }).to eq([ 30, 60, 480, 900 ])
  end

  it "does not delete poison messages: after maxReceiveCount SQS moves them to the dead-letter queue" do
    sqs.stub_responses(:receive_message, messages: [ message("{not json"), message({ "hello" => "world" }) ])

    consumer.poll_once

    expect(requests(:delete_message)).to be_empty
    expect(requests(:change_message_visibility).size).to eq(2)
  end

  it "keeps polling through an AWS outage and reports it" do
    sqs.stub_responses(:receive_message, "InternalFailure")
    expect(Rails.error).to receive(:report).with(instance_of(Aws::SQS::Errors::InternalFailure), hash_including(handled: true))

    expect { consumer.poll_once }.not_to raise_error
    expect(Notifications::Heartbeat.age).to be < 1
  end

  it "stops when asked" do
    sqs.stub_responses(:receive_message, ->(_context) { consumer.stop; { messages: [] } })

    Timeout.timeout(5) { consumer.run }

    expect(requests(:receive_message).size).to eq(1)
  end

  it "needs a queue" do
    expect { described_class.new(queue_url: nil, client: sqs) }.to raise_error(ArgumentError, /NOTIFICATIONS_QUEUE_URL/)
  end

  it "counts what it did" do
    sqs.stub_responses(:receive_message, messages: [ message(assigned_event) ])

    expect { consumer.poll_once }.to change { Notifications::Metrics::PROCESSED.get(labels: { type: "task.assigned", outcome: "handled" }) }.by(1)
  end
end
