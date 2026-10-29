require "rails_helper"

RSpec.describe Ai::Gateway::Remote do
  let(:gateway) { described_class.new(url: "http://ai.test", token: "service-token") }
  let(:usage) { { "input_tokens" => 12, "output_tokens" => 3, "model_id" => "m", "latency_ms" => 40 } }

  it "calls a feature and rebuilds AiCore's result" do
    stub = stub_request(:post, "http://ai.test/v1/features/parse_task")
      .with(headers: { "Authorization" => "Bearer service-token", "Content-Type" => "application/json" },
            body: { input: { text: "hi", today: "2026-10-29" } }.to_json)
      .to_return(status: 200, body: { output: { title: "Hi", due_on: nil }, usage: usage }.to_json)

    result = gateway.run("parse_task", { text: "hi", today: "2026-10-29" })

    expect(stub).to have_been_requested
    expect(result.output).to eq(title: "Hi", due_on: nil)
    expect(result.usage).to have_attributes(input_tokens: 12, output_tokens: 3, model_id: "m")
  end

  it "relays a tool-use turn" do
    stub_request(:post, "http://ai.test/v1/converse").to_return(status: 200, body: {
      message: { role: "assistant", content: [ { tool_use: { tool_use_id: "1", name: "list_tasks", input: { overdue: true } } } ] },
      stop_reason: "tool_use", usage: usage
    }.to_json)

    response = gateway.converse(system: "s", messages: [], tools: [])

    expect(response.tool_uses.sole).to include(name: "list_tasks", input: { overdue: true })
  end

  it "fetches embeddings" do
    stub_request(:post, "http://ai.test/v1/embeddings").with(body: { text: "hello" }.to_json)
      .to_return(status: 200, body: { vector: [ 0.1, 0.2 ], usage: usage }.to_json)

    expect(gateway.embed("hello").vector).to eq([ 0.1, 0.2 ])
  end

  {
    "ai_not_configured" => [ 503, Ai::Disabled ],
    "ai_unavailable" => [ 503, Ai::Unavailable ],
    "ai_invalid_response" => [ 502, Ai::InvalidResponse ],
    "rate_limited" => [ 429, Ai::Unavailable ]
  }.each do |code, (status, error_class)|
    it "maps the service's #{code} error to #{error_class}" do
      stub_request(:post, "http://ai.test/v1/embeddings").to_return(status: status, body: { error: { code: code } }.to_json)

      expect { gateway.embed("x") }.to raise_error(error_class)
    end
  end

  it "treats an unreachable service as unavailable" do
    stub_request(:post, "http://ai.test/v1/embeddings").to_timeout

    expect { gateway.embed("x") }.to raise_error(Ai::Unavailable, /unreachable/)
  end

  it "is disabled without a URL" do
    expect(described_class.new(url: nil, token: nil)).not_to be_enabled
    expect { described_class.new(url: nil, token: nil).embed("x") }.to raise_error(Ai::Disabled)
  end
end
