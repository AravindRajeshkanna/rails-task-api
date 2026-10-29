# Test doubles for the AI layer. By default the suite uses ai_core's offline fake provider (deterministic
# heuristics, hashed bag-of-words embeddings); examples can script exact model answers instead.
module AiHelpers
  # Runs the block with a scripted provider. The responder is a lambda taking the request hash and
  # returning an AiCore::Response (see +tool_answer+ / +text_answer+), or raising an AiCore::Error.
  def with_ai_responder(responder)
    previous = AiCore.client
    provider = AiCore::Providers::Fake.new(AiCore.configuration, responder: responder)
    AiCore.client = AiCore::Client.new(provider: provider, config: AiCore.configuration)
    yield provider
  ensure
    AiCore.client = previous
  end

  def tool_answer(name, input, tokens: [ 100, 20 ])
    AiCore::Response.new(
      message: { role: "assistant", content: [ { tool_use: { tool_use_id: "t-#{name}", name: name, input: input } } ] },
      stop_reason: "tool_use", usage: ai_usage(*tokens)
    )
  end

  def text_answer(text, tokens: [ 50, 10 ])
    AiCore::Response.new(message: { role: "assistant", content: [ { text: text } ] }, stop_reason: "end_turn", usage: ai_usage(*tokens))
  end

  def ai_usage(input, output) = AiCore::Usage.new(input_tokens: input, output_tokens: output, model_id: "test-model", latency_ms: 25)

  def with_embeddings
    original = Ai.config.embeddings
    Ai.config.embeddings = true
    yield
  ensure
    Ai.config.embeddings = original
  end

  # Gives +task+ its embedding the way the background job would.
  def embed(*tasks) = tasks.each { |task| Ai::Embedder.call(task) }
end

RSpec.configure { |config| config.include AiHelpers }
