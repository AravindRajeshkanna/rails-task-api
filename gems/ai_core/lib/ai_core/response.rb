module AiCore
  # The canonical shapes every provider speaks. Messages use the Bedrock Converse layout:
  #
  #   { role: "user" | "assistant", content: [ { text: "..." },
  #                                           { tool_use: { tool_use_id:, name:, input: } },
  #                                           { tool_result: { tool_use_id:, content: [ { text: "..." } ], status: } } ] }

  # One model turn.
  Response = Struct.new(:message, :stop_reason, :usage, keyword_init: true) do
    def content = message.fetch(:content)
    def text = content.filter_map { |block| block[:text] }.join
    def tool_uses = content.filter_map { |block| block[:tool_use] }

    def to_h = { message: message, stop_reason: stop_reason, usage: usage.to_h }
  end

  # A vector plus what it cost.
  Embedding = Struct.new(:vector, :usage, keyword_init: true)

  # A validated feature result.
  Result = Struct.new(:output, :usage, keyword_init: true)
end
