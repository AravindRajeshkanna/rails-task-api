require "spec_helper"
require_relative "support"
require "aiops/rca"

RSpec.describe Aiops::Rca do
  let(:sns) { sns_client }
  let(:env) { { "ENVIRONMENT" => "prod", "CLUSTER_NAME" => "task-api-prod", "APP_LOG_GROUP" => "/aws/containerinsights/task-api-prod/application", "ALERTS_TOPIC_ARN" => "arn:aws:sns:us-east-1:1:alerts" } }
  let(:alarm) { Aiops::Alarm.from_sns(alarm_event(name: "task-api-prod-queue-latency")) }
  let(:evidence) { instance_double(Aiops::Evidence, collect: { "recent_deploys" => [ { "workload" => "worker", "image" => "worker:abc1234", "minutes_ago" => 6 } ] }) }

  def scripted_client(output)
    config = AiCore.configuration
    responder = ->(request) {
      AiCore::Response.new(message: { role: "assistant", content: [ { tool_use: { tool_use_id: "t", name: request[:tool_choice].dig(:tool, :name), input: output } } ] },
                           stop_reason: "tool_use", usage: AiCore::Usage.new(input_tokens: 1, output_tokens: 1))
    }
    AiCore::Client.new(provider: AiCore::Providers::Fake.new(config, responder: responder), config: config)
  end

  it "posts the analysis next to the alarm, labelled as AI output and marked so it is never re-analyzed" do
    client = scripted_client("summary" => "Workers stopped after a deploy", "likely_cause" => "worker:abc1234 rolled out 6 minutes before the alarm (recent_deploys)",
                             "confidence" => "medium", "suggested_actions" => [ "Roll back worker", "Check boot logs" ], "runbook" => "queue-backlog")

    described_class.process(alarm, env: env, sns: sns, evidence: evidence, client: client)

    message = published(sns).sole
    expect(message[:subject]).to eq("RCA: Workers stopped after a deploy")
    expect(message[:message]).to include("Likely cause (medium confidence)", "rolled out 6 minutes before", "Runbook: docs/runbooks/queue-backlog.md", "1. Roll back worker", "can be wrong")
    expect(message[:message_attributes]).to include("kind" => { data_type: "String", string_value: "rca" }, "alarm" => { data_type: "String", string_value: "task-api-prod-queue-latency" })
  end

  it "passes the evidence and the known runbooks to the model, and nothing it may act with" do
    seen = nil
    config = AiCore.configuration
    client = AiCore::Client.new(provider: AiCore::Providers::Fake.new(config, responder: ->(request) {
      seen = request
      AiCore::Response.new(message: { role: "assistant", content: [ { tool_use: { tool_use_id: "t", name: "analyze_incident", input: { "summary" => "s", "likely_cause" => "c" } } } ] },
                           stop_reason: "tool_use", usage: AiCore::Usage.new(input_tokens: 1, output_tokens: 1))
    }), config: config)

    described_class.process(alarm, env: env, sns: sns, evidence: evidence, client: client)

    input = AiCore::Prompting.extract_input(seen[:messages].first[:content].first[:text])
    expect(input).to include("environment" => "prod", "runbooks" => described_class::RUNBOOKS)
    expect(input["alarm"]).to include("name" => "task-api-prod-queue-latency")
    expect(input["evidence"]["recent_deploys"].first).to include("image" => "worker:abc1234")
    expect(seen[:tools].map { |tool| tool[:name] }).to eq([ "analyze_incident" ])
  end

  it "works end to end with the offline model" do
    described_class.process(alarm, env: env, sns: sns, evidence: evidence)

    expect(published(sns).sole[:message]).to include("Heuristic baseline", "a deploy happened")
  end

  it "only analyzes alarms that are firing" do
    expect(described_class.handler(event: alarm_event(state: "OK"))).to eq(skipped: "state OK")
    expect(described_class.handler(event: alarm_event(message: "plain text"))).to eq(skipped: "not an alarm")
  end
end
