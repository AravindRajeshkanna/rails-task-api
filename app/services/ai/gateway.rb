module Ai
  # Where inference runs. Callers never know which:
  #
  #   local   the ai_core gem inside this process (Phase 1, and the default for development)
  #   remote  HTTP calls to the AI service (services/ai), selected with AI_GATEWAY=remote
  #
  # Both speak AiCore's types, so switching (or rolling back) is a configuration change.
  module Gateway
    def self.current = @current ||= build

    def self.build
      case Ai.config.gateway
      when "remote" then Remote.new(url: Ai.config.service_url, token: Ai.config.service_token)
      when "local" then Local.new
      else raise ArgumentError, "AI_GATEWAY must be local or remote, got #{Ai.config.gateway.inspect}"
      end
    end

    # Tests and the console can swap the gateway; pass nil to rebuild from configuration.
    def self.current=(gateway)
      @current = gateway
    end
  end
end
