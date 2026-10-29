module V1
  # POST /v1/converse  { "system": "...", "messages": [...], "tools": [...] }
  # One model turn. The caller runs the tool loop, so tools execute (and are authorized) where the data lives.
  class ConversationsController < ApplicationController
    MAX_MESSAGES = 60
    MAX_TOOLS = 20

    def create
      system = params.require(:system).to_s
      messages = params.require(:messages).map { |message| deep_plain(message) }
      tools = Array(params[:tools]).map { |tool| deep_plain(tool) }
      return render_error(:unprocessable_content, "invalid_request", "Too many messages or tools") if messages.size > MAX_MESSAGES || tools.size > MAX_TOOLS

      response = AiService::Inference.call("converse") do
        AiCore.client.converse(system: system, messages: messages.map(&:deep_symbolize_keys), tools: tools.map(&:deep_symbolize_keys))
      end
      render json: response.to_h
    end

    private
      def deep_plain(value) = JSON.parse(value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h.to_json : value.to_json)
  end
end
