require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_mailbox/engine"
require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module TaskApi
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    config.api_only = true

    # Errors raised outside controllers (bad JSON, unknown routes) are rendered by
    # ErrorsController so every failure has the same JSON envelope.
    config.exceptions_app = routes

    # Signed blob URLs handed to clients stop working after 10 minutes.
    config.active_storage.urls_expire_in = 10.minutes

    # App-specific settings (read with Rails.configuration.x.*).
    config.x.base_url = ENV.fetch("APP_BASE_URL", "http://localhost:3000")
    config.x.frontend_url = ENV.fetch("FRONTEND_URL", "http://localhost:5173")
    config.x.mail_from = ENV.fetch("MAIL_FROM", "Task API <no-reply@example.com>")
    config.x.discard_retention = 30.days
    # A public demo instance: sign-up, password reset, uploads, webhooks, invitations and AI are refused, and its data is
    # reset every night (docs/demo.md). Never set this on an instance with real users.
    config.x.demo_mode = ENV["DEMO_MODE"] == "true"
    # Outgoing webhooks refuse private/loopback addresses unless this is enabled (SSRF guard).
    config.x.webhooks.allow_private_networks = false

    # Who authenticates users. local: this app issues and checks session tokens (the default).
    # jwt: the Auth service (services/auth) does, and this app only verifies its JWTs.
    config.x.auth.mode = ENV.fetch("AUTH_MODE", "local")
    config.x.auth.issuer = ENV["AUTH_ISSUER"]
    config.x.auth.audience = ENV.fetch("AUTH_AUDIENCE", "task-api")
    config.x.auth.jwks_url = ENV["AUTH_JWKS_URL"]

    # Who sends assignment and reminder emails. local: this app's mailers. remote: the Notification
    # service, which consumes the task.assigned / task.due_soon events (set once it is deployed).
    config.x.notifications.mode = ENV.fetch("NOTIFICATIONS_MODE", "local")

    # Domain events published to SNS for the other services (unset = not published).
    config.x.events.sns_topic_arn = ENV["EVENTS_SNS_TOPIC_ARN"]

    # AI features (see app/services/ai and gems/ai_core). Provider and model come from AiCore's own
    # environment (AI_PROVIDER, AI_MODEL_ID, ...); these are the app-side controls.
    config.x.ai.gateway = ENV.fetch("AI_GATEWAY", "local") # local = in this process; remote = the AI service
    config.x.ai.service_url = ENV["AI_SERVICE_URL"]
    config.x.ai.service_token = ENV["AI_SERVICE_TOKEN"]
    config.x.ai.daily_tokens_per_user = Integer(ENV.fetch("AI_DAILY_TOKENS_PER_USER", 200_000))
    config.x.ai.daily_tokens_per_project = Integer(ENV.fetch("AI_DAILY_TOKENS_PER_PROJECT", 1_000_000))
    config.x.ai.requests_per_minute = Integer(ENV.fetch("AI_REQUESTS_PER_MINUTE", 20))
    config.x.ai.summary_ttl = 10.minutes
    config.x.ai.similar_task_max_distance = 0.6 # cosine distance; smaller = more alike
    config.x.ai.embeddings = ENV.fetch("AI_EMBEDDINGS", Rails.env.test? ? "false" : "true") == "true"
  end
end
