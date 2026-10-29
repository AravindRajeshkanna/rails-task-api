module AiCore
  # Token accounting for one or more model calls.
  Usage = Struct.new(:input_tokens, :output_tokens, :model_id, :latency_ms, keyword_init: true) do
    def self.zero = new(input_tokens: 0, output_tokens: 0, latency_ms: 0)

    def total_tokens = input_tokens.to_i + output_tokens.to_i

    def +(other)
      self.class.new(
        input_tokens: input_tokens.to_i + other.input_tokens.to_i,
        output_tokens: output_tokens.to_i + other.output_tokens.to_i,
        model_id: other.model_id || model_id,
        latency_ms: latency_ms.to_i + other.latency_ms.to_i
      )
    end

    # Prices are USD per million tokens, so tokens * price is already micro-dollars.
    def cost_micros(config = AiCore.configuration)
      (input_tokens.to_i * config.price_input_per_mtok + output_tokens.to_i * config.price_output_per_mtok).round
    end

    def to_h = { input_tokens: input_tokens.to_i, output_tokens: output_tokens.to_i, model_id: model_id, latency_ms: latency_ms.to_i }
  end
end
