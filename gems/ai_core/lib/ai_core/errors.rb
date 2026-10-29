module AiCore
  class Error < StandardError; end

  # AI_PROVIDER / AI_MODEL_ID are missing or unknown.
  class ConfigurationError < Error; end

  # The provider is throttling, timing out or down. Callers should retry later (HTTP 503).
  class Unavailable < Error; end

  # The model answered, but not with something that satisfies the feature's contract.
  class InvalidResponse < Error; end
end
