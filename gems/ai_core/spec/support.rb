require "ai_core"

module AiCoreHelpers
  def ai_config(**overrides)
    AiCore::Configuration.new(
      provider: "fake", model_id: "test-model", embedding_model_id: "test-embed", embedding_dimensions: 32,
      region: "us-east-1", max_output_tokens: 256, timeout: 5.0, price_input_per_mtok: 3.0, price_output_per_mtok: 15.0, **overrides
    )
  end

  def usage(input: 10, output: 5) = AiCore::Usage.new(input_tokens: input, output_tokens: output, model_id: "test-model", latency_ms: 12)

  # A provider whose answer to a forced tool call is +output+.
  def scripted_client(output, config = ai_config)
    responder = lambda do |request|
      name = request[:tool_choice].dig(:tool, :name)
      AiCore::Response.new(
        message: { role: "assistant", content: [ { tool_use: { tool_use_id: "t1", name: name, input: output } } ] },
        stop_reason: "tool_use", usage: usage
      )
    end
    AiCore::Client.new(provider: AiCore::Providers::Fake.new(config, responder: responder), config: config)
  end
end

# Only for this gem's own specs. Included everywhere, `usage` would silently override a `let(:usage)` in
# an app spec whenever both suites run in one process.
RSpec.configure { |config| config.include AiCoreHelpers, file_path: %r{/gems/ai_core/spec/} }
