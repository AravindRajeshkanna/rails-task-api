require "json"
require "date"

require_relative "ai_core/version"
require_relative "ai_core/errors"
require_relative "ai_core/configuration"
require_relative "ai_core/usage"
require_relative "ai_core/response"
require_relative "ai_core/prompting"
require_relative "ai_core/features"
require_relative "ai_core/providers"
require_relative "ai_core/client"
require_relative "ai_core/eval/runner"

# Provider-agnostic LLM inference: prompts, validated structured output, tool-use turns and embeddings.
module AiCore
  class << self
    def configuration = @configuration ||= Configuration.from_env
    def configure = yield(configuration)

    # A client for the configured provider. Raises ConfigurationError when AI is not configured.
    def client = @client ||= Client.new(provider: Providers.build(configuration), config: configuration)
    attr_writer :client

    def enabled? = configuration.enabled?

    def reset!
      @configuration = nil
      @client = nil
    end
  end
end
