module Ai
  module Gateway
    class Local
      def enabled? = AiCore.enabled? # rubocop:disable Rails/Delegate -- a module function, not an object to delegate to

      def run(feature, input) = guard { AiCore.client.run(feature, input) }
      def converse(system:, messages:, tools: []) = guard { AiCore.client.converse(system: system, messages: messages, tools: tools) }
      def embed(text) = guard { AiCore.client.embed(text) }

      private
        def guard
          yield
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
