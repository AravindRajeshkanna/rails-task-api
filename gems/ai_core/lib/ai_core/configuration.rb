module AiCore
  # Settings come from the environment so the same image runs everywhere:
  #
  #   AI_PROVIDER              bedrock | fake            (unset = AI disabled)
  #   AI_MODEL_ID              Bedrock model or inference-profile id (required for bedrock)
  #   AI_EMBEDDING_MODEL_ID    default amazon.titan-embed-text-v2:0
  #   AI_EMBEDDING_DIMENSIONS  256 | 512 | 1024 (default 1024; must match the pgvector column)
  #   AI_MAX_OUTPUT_TOKENS     default 1024
  #   AI_TIMEOUT               seconds to wait for the model, default 20
  #   AI_PRICE_INPUT_PER_MTOK / AI_PRICE_OUTPUT_PER_MTOK   USD per million tokens, for cost tracking
  Configuration = Struct.new(
    :provider, :model_id, :embedding_model_id, :embedding_dimensions, :region,
    :max_output_tokens, :timeout, :price_input_per_mtok, :price_output_per_mtok,
    keyword_init: true
  ) do
    def self.from_env(env = ENV)
      new(
        provider: blank(env["AI_PROVIDER"]),
        model_id: blank(env["AI_MODEL_ID"]),
        embedding_model_id: blank(env["AI_EMBEDDING_MODEL_ID"]) || "amazon.titan-embed-text-v2:0",
        embedding_dimensions: Integer(env.fetch("AI_EMBEDDING_DIMENSIONS", 1024)),
        region: blank(env["AWS_REGION"]) || blank(env["AWS_DEFAULT_REGION"]) || "us-east-1",
        max_output_tokens: Integer(env.fetch("AI_MAX_OUTPUT_TOKENS", 1024)),
        timeout: Float(env.fetch("AI_TIMEOUT", 20)),
        price_input_per_mtok: Float(env.fetch("AI_PRICE_INPUT_PER_MTOK", 0)),
        price_output_per_mtok: Float(env.fetch("AI_PRICE_OUTPUT_PER_MTOK", 0))
      )
    end

    def self.blank(value)
      value = value.to_s.strip
      value unless value.empty?
    end

    def enabled? = !provider.nil?
  end
end
