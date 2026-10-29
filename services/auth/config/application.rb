require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_record/railtie"
require "action_controller/railtie"

Bundler.require(*Rails.groups)

# The Auth service: owns users and credentials, issues short-lived RS256 access tokens plus rotating
# refresh tokens, and publishes its public keys at /.well-known/jwks.json for everyone else to verify with.
module AuthService
  class Application < Rails::Application
    config.load_defaults 8.1
    config.api_only = true
    config.service_kit.name = "auth-service"

    config.x.auth.issuer = ENV.fetch("AUTH_ISSUER", "http://localhost:3100")
    config.x.auth.audience = ENV.fetch("AUTH_AUDIENCE", "task-api")
    config.x.auth.access_ttl = Integer(ENV.fetch("AUTH_ACCESS_TOKEN_TTL", 15 * 60)).seconds
    config.x.auth.refresh_ttl = Integer(ENV.fetch("AUTH_REFRESH_TOKEN_TTL", 30 * 24 * 3600)).seconds
    config.x.frontend_url = ENV.fetch("FRONTEND_URL", "http://localhost:5173")
    config.x.events.sns_topic_arn = ENV["EVENTS_SNS_TOPIC_ARN"]
  end
end
