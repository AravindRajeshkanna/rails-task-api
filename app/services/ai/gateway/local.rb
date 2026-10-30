module Ai
  module Gateway
    class Local
      def enabled? = AiCore.enabled? # rubocop:disable Rails/Delegate -- a module function, not an object to delegate to

      def run(feature, input) = guard { AiCore.client.run(feature, input) }
      def converse(system:, messages:, tools: []) = guard { AiCore.client.converse(system: system, messages: messages, tools: tools) }
      def embed(text) = guard { AiCore.client.embed(text) }

      private
        # The provider (Bedrock) down for real means each call can hold a thread for the timeout plus the SDK's own retries. Five failures in a row
        # and it is not called for 30 s (then longer): requests fail at once with a Retry-After (ADR 58).
        def breaker = ServiceKit::CircuitBreaker.for(:ai_provider, failure_threshold: 5, window: 30, reset_timeout: 30, exceptions: [ AiCore::Unavailable ])

        def guard(&)
          breaker.call(&)
        rescue ServiceKit::CircuitBreaker::OpenError => error
          raise Ai::Unavailable.new("AI provider is failing; not calling it for #{error.retry_after}s", retry_after: error.retry_after)
        rescue AiCore::ConfigurationError => error
          raise Ai::Disabled, error.message
        rescue AiCore::Unavailable => error
          raise Ai::Unavailable, error.message
        rescue AiCore::InvalidResponse => error
          raise Ai::InvalidResponse, error.message
        rescue AiCore::Error => error
          raise Ai::Error, error.message
        end
    end
  end
end
