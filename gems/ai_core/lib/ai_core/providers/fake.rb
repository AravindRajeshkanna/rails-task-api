require_relative "fake/heuristics"

module AiCore
  module Providers
    # An offline stand-in for development, the test suite and demos without AWS access.
    #
    # Out of the box it answers with rule-based heuristics (see Fake::Heuristics) and hashed
    # bag-of-words embeddings, so similar texts are close together. Tests script exact answers:
    #
    #   AiCore::Providers::Fake.new(config, responder: ->(request) { Response.new(...) })
    class Fake
      attr_reader :requests

      def initialize(config, responder: nil)
        @config = config
        @responder = responder
        @requests = []
      end

      def converse(system:, messages:, tools: [], tool_choice: nil, max_tokens: nil, temperature: 0.0)
        request = { system: system, messages: messages, tools: tools, tool_choice: tool_choice }
        @requests << request

        return @responder.call(request) if @responder

        forced = tool_choice&.dig(:tool, :name)
        content = forced ? [ forced_tool_use(forced, messages) ] : Heuristics.chat_turn(messages)
        Response.new(
          message: { role: "assistant", content: content },
          stop_reason: content.any? { |block| block[:tool_use] } ? "tool_use" : "end_turn",
          usage: Usage.new(input_tokens: estimate_tokens(system, messages), output_tokens: 40, model_id: "fake", latency_ms: 1)
        )
      end

      def embed(text)
        Embedding.new(
          vector: Heuristics.embedding(text, @config.embedding_dimensions),
          usage: Usage.new(input_tokens: [ text.length / 4, 1 ].max, output_tokens: 0, model_id: "fake-embedding", latency_ms: 1)
        )
      end

      private
        def forced_tool_use(name, messages)
          prompt = messages.last.fetch(:content).filter_map { |block| block[:text] }.join
          input = Prompting.extract_input(prompt) || {}
          { tool_use: { tool_use_id: "fake-#{name}", name: name, input: Heuristics.answer(name, input) } }
        end

        def estimate_tokens(system, messages)
          (system.length + messages.sum { |message| message.to_json.length }) / 4
        end
    end
  end
end
