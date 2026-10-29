require "spec_helper"
require_relative "../support"

RSpec.describe AiCore::Providers::Bedrock do
  let(:sdk) { Aws::BedrockRuntime::Client.new(stub_responses: true, region: "us-east-1") }
  let(:provider) { described_class.new(ai_config(provider: "bedrock"), client: sdk) }

  it "maps a Converse tool-use answer to the canonical response" do
    sdk.stub_responses(:converse,
      output: { message: { role: "assistant", content: [ { text: "thinking" }, { tool_use: { tool_use_id: "t1", name: "parse_task", input: { "title" => "x" } } } ] } },
      stop_reason: "tool_use", usage: { input_tokens: 120, output_tokens: 30, total_tokens: 150 }, metrics: { latency_ms: 80 })

    response = provider.converse(system: "sys", messages: [ { role: "user", content: [ { text: "hi" } ] } ], tools: [ { name: "parse_task", description: "d", input_schema: { type: "object" } } ], tool_choice: { tool: { name: "parse_task" } })

    expect(response.text).to eq("thinking")
    expect(response.tool_uses.first).to include(tool_use_id: "t1", name: "parse_task", input: { "title" => "x" })
    expect(response.stop_reason).to eq("tool_use")
    expect(response.usage).to have_attributes(input_tokens: 120, output_tokens: 30, model_id: "test-model")
  end

  it "sends the tool config and inference settings Bedrock expects" do
    provider.converse(system: "sys", messages: [], tools: [ { name: "t", description: "d", input_schema: { type: "object" } } ], tool_choice: { tool: { name: "t" } })
    params = sdk.api_requests.last[:params]

    expect(params).to include(model_id: "test-model", system: [ { text: "sys" } ], inference_config: { max_tokens: 256, temperature: 0.0 })
    expect(params[:tool_config]).to eq(
      tools: [ { tool_spec: { name: "t", description: "d", input_schema: { json: { type: "object" } } } } ],
      tool_choice: { tool: { name: "t" } }
    )
  end

  it "embeds with Titan and reports the token count" do
    sdk.stub_responses(:invoke_model, body: { embedding: [ 0.1, 0.2 ], inputTextTokenCount: 7 }.to_json, content_type: "application/json")

    embedding = provider.embed("hello")

    expect(embedding.vector).to eq([ 0.1, 0.2 ])
    expect(embedding.usage).to have_attributes(input_tokens: 7, model_id: "test-embed")
    expect(JSON.parse(sdk.api_requests.last[:params][:body])).to eq("inputText" => "hello", "dimensions" => 32, "normalize" => true)
  end

  it "turns throttling into Unavailable and other service errors into Error" do
    sdk.stub_responses(:converse, "ThrottlingException")
    expect { provider.converse(system: "s", messages: []) }.to raise_error(AiCore::Unavailable)

    sdk.stub_responses(:converse, "AccessDeniedException")
    expect { provider.converse(system: "s", messages: []) }.to raise_error(AiCore::Error, /AccessDeniedException/)
  end

  it "needs a model id" do
    expect { described_class.new(ai_config(model_id: nil), client: sdk) }.to raise_error(AiCore::ConfigurationError, /AI_MODEL_ID/)
  end
end
