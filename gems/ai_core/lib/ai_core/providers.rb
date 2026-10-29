require_relative "providers/bedrock"
require_relative "providers/fake"

module AiCore
  module Providers
    def self.build(config)
      case config.provider
      when "bedrock" then Bedrock.new(config)
      when "fake" then Fake.new(config)
      when nil then raise ConfigurationError, "AI_PROVIDER is not set (use bedrock or fake)"
      else raise ConfigurationError, "Unknown AI_PROVIDER #{config.provider.inspect} (use bedrock or fake)"
      end
    end
  end
end
