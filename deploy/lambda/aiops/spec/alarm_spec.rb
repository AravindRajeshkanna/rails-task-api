require "spec_helper"
require_relative "support"

RSpec.describe Aiops::Alarm do
  it "reads a CloudWatch alarm from an SNS event" do
    alarm = described_class.from_sns(alarm_event)

    expect(alarm).to have_attributes(name: "task-api-prod-queue-backlog", state: "ALARM", previous_state: "OK", metric: "QueueDepth", namespace: "TaskApi")
    expect(alarm).to be_firing
    expect(alarm.key("prod")).to eq("queue-backlog")
  end

  it "ignores messages that are not alarms: ECR findings, budgets, plain text" do
    expect(described_class.from_sns(alarm_event(message: { "detail-type" => "ECR Image Scan" }))).to be_nil
    expect(described_class.from_sns(alarm_event(message: "You have exceeded your budget"))).to be_nil
  end

  it "never picks up its own output, so analyses cannot trigger analyses" do
    event = alarm_event(attributes: { "kind" => { "Type" => "String", "Value" => "rca" } })

    expect(described_class.from_sns(event)).to be_nil
  end

  it "survives a malformed event" do
    expect(described_class.from_sns({ "Records" => [] })).to be_nil
    expect(described_class.from_sns({})).to be_nil
  end
end
