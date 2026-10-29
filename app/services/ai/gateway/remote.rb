require "net/http"

module Ai
  module Gateway
    # Talks to the AI service (services/ai). The wire format is AiCore's own: see
    # docs/architecture/service-contracts.md. Trace headers are added by the OpenTelemetry Net::HTTP
    # instrumentation, so a request is one trace across both services.
    class Remote
      OPEN_TIMEOUT = 3
      READ_TIMEOUT = 30

      def initialize(url:, token:)
        @url = url
        @token = token
      end

      def enabled? = @url.present?

      def run(feature, input)
        body = post("/v1/features/#{feature}", input: input)
        AiCore::Result.new(output: body.fetch("output").deep_symbolize_keys, usage: usage(body))
      end

      def converse(system:, messages:, tools: [])
        body = post("/v1/converse", system: system, messages: messages, tools: tools)
        AiCore::Response.new(
          message: { role: "assistant", content: body.dig("message", "content").map(&:deep_symbolize_keys) },
          stop_reason: body["stop_reason"],
          usage: usage(body)
        )
      end

      def embed(text)
        body = post("/v1/embeddings", text: text)
        AiCore::Embedding.new(vector: body.fetch("vector"), usage: usage(body))
      end

      private
        def post(path, payload)
          raise Ai::Disabled, "AI_SERVICE_URL is not set" unless enabled?

          uri = URI.join(@url, path)
          request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json", "Accept" => "application/json")
          request["Authorization"] = "Bearer #{@token}" if @token.present?
          request.body = payload.to_json

          response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
            http.request(request)
          end
          handle(response)
        rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError => error
          raise Ai::Unavailable, "AI service unreachable: #{error.class}"
        end

        def handle(response)
          return JSON.parse(response.body) if response.is_a?(Net::HTTPSuccess)

          code = JSON.parse(response.body).dig("error", "code") rescue nil
          message = "AI service answered #{response.code}#{" (#{code})" if code}"
          case code
          when "ai_not_configured" then raise Ai::Disabled, message
          when "ai_invalid_response" then raise Ai::InvalidResponse, message
          when "ai_unavailable", "rate_limited" then raise Ai::Unavailable, message
          else raise(response.code.to_i >= 500 ? Ai::Unavailable : Ai::Error, message)
          end
        end

        def usage(body)
          AiCore::Usage.new(**(body["usage"] || {}).symbolize_keys.slice(:input_tokens, :output_tokens, :model_id, :latency_ms))
        end
    end
  end
end
