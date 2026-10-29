require_relative "boot"

require "rails"
require "active_model/railtie"
require "action_controller/railtie"

Bundler.require(*Rails.groups)

# The AI service: stateless LLM inference behind HTTP (features, tool-use turns, embeddings).
# No database. The monolith (or any service) sends the context; this service holds the model credentials.
module AiService
  class Application < Rails::Application
    config.load_defaults 8.1
    config.api_only = true
    config.service_kit.name = "ai-service"
    config.x.rate_limit_per_minute = Integer(ENV.fetch("AI_SERVICE_RATE_LIMIT", 600))
  end
end
