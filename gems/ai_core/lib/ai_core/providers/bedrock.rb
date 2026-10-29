require "aws-sdk-bedrockruntime"

module AiCore
  module Providers
    # Amazon Bedrock through the Converse API, which speaks one message format for Claude, Nova,
    # Llama and Mistral models, and InvokeModel for Titan embeddings. Credentials come from the
    # standard AWS chain (EKS Pod Identity / IRSA in production, your profile locally).
    class Bedrock
      UNAVAILABLE = [
        Aws::BedrockRuntime::Errors::ThrottlingException,
        Aws::BedrockRuntime::Errors::ServiceUnavailableException,
        Aws::BedrockRuntime::Errors::ModelTimeoutException,
        Aws::BedrockRuntime::Errors::ModelNotReadyException,
        Seahorse::Client::NetworkingError
      ].freeze

      def initialize(config, client: nil)
        @config = config
        raise ConfigurationError, "AI_MODEL_ID is required for the bedrock provider" if config.model_id.nil?

        @client = client || Aws::BedrockRuntime::Client.new(
          region: config.region, http_open_timeout: 5, http_read_timeout: config.timeout, retry_limit: 2
        )
      end

      def converse(system:, messages:, tools: [], tool_choice: nil, max_tokens: @config.max_output_tokens, temperature: 0.0)
        params = {
          model_id: @config.model_id,
          system: [ { text: system } ],
          messages: messages,
          inference_config: { max_tokens: max_tokens, temperature: temperature }
        }
        params[:tool_config] = tool_config(tools, tool_choice) if tools.any?

        started = monotonic_ms
        output = guard { @client.converse(**params) }

        Response.new(
          message: { role: "assistant", content: output.output.message.content.filter_map { |block| content_block(block) } },
          stop_reason: output.stop_reason,
          usage: Usage.new(
            input_tokens: output.usage.input_tokens, output_tokens: output.usage.output_tokens,
            model_id: @config.model_id, latency_ms: monotonic_ms - started
          )
        )
      end

      def embed(text)
        started = monotonic_ms
        body = { inputText: text, dimensions: @config.embedding_dimensions, normalize: true }.to_json
        output = guard {
          @client.invoke_model(model_id: @config.embedding_model_id, content_type: "application/json", accept: "application/json", body: body)
        }
        payload = JSON.parse(output.body.read)

        Embedding.new(
          vector: payload.fetch("embedding"),
          usage: Usage.new(
            input_tokens: payload["inputTextTokenCount"], output_tokens: 0,
            model_id: @config.embedding_model_id, latency_ms: monotonic_ms - started
          )
        )
      end

      private
        def tool_config(tools, tool_choice)
          config = {
            tools: tools.map { |tool|
              { tool_spec: { name: tool[:name], description: tool[:description], input_schema: { json: tool[:input_schema] } } }
            }
          }
          config[:tool_choice] = tool_choice if tool_choice
          config
        end

        def content_block(block)
          if block.text
            { text: block.text }
          elsif block.tool_use
            { tool_use: { tool_use_id: block.tool_use.tool_use_id, name: block.tool_use.name, input: block.tool_use.input } }
          end
        end

        def guard
          yield
        rescue *UNAVAILABLE => error
          raise Unavailable, error.message
        rescue Aws::Errors::ServiceError => error
          raise Error, "#{error.class.name.split('::').last}: #{error.message}"
        end

        def monotonic_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
    end
  end
end
