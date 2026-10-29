module AiCore
  # The one entry point callers use: structured features, raw tool-use turns and embeddings.
  class Client
    MAX_INPUT_CHARS = 60_000

    attr_reader :provider, :config

    def initialize(provider:, config: AiCore.configuration)
      @provider = provider
      @config = config
    end

    # Runs a feature (see AiCore::Features) and returns a validated Result.
    def run(feature_name, input)
      feature = Features.fetch(feature_name)
      input = JSON.parse(JSON.generate(input)) # string keys everywhere, like the HTTP boundary
      prompt = feature.user_prompt(input)
      raise InvalidResponse, "#{feature.feature_name}: input is too large" if prompt.length > MAX_INPUT_CHARS

      response = provider.converse(
        system: feature.system_prompt,
        messages: [ { role: "user", content: [ { text: prompt } ] } ],
        tools: [ feature.tool ],
        tool_choice: { tool: { name: feature.feature_name } }
      )

      Result.new(output: feature.normalize(raw_output(response, feature), input), usage: response.usage)
    end

    # One model turn with caller-supplied tools. The caller owns the loop (and executes the tools),
    # which keeps authorization with the system that holds the data.
    def converse(system:, messages:, tools: [])
      provider.converse(system: system, messages: messages, tools: tools)
    end

    def embed(text)
      text = text.to_s[0, 8_000]
      raise InvalidResponse, "cannot embed empty text" if text.strip.empty?

      provider.embed(text)
    end

    private
      # Models that ignore tool_choice sometimes answer with a JSON object in plain text.
      def raw_output(response, feature)
        tool_use = response.tool_uses.find { |use| use[:name] == feature.feature_name }
        return JSON.parse(JSON.generate(tool_use[:input])) if tool_use

        json = response.text[/\{.*\}/m]
        json ? JSON.parse(json) : raise(InvalidResponse, "#{feature.feature_name}: the model did not return structured output")
      rescue JSON::ParserError
        raise InvalidResponse, "#{feature.feature_name}: the model returned malformed JSON"
      end
  end
end
