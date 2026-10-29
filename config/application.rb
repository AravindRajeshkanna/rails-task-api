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
    # Outgoing webhooks refuse private/loopback addresses unless this is enabled (SSRF guard).
    config.x.webhooks.allow_private_networks = false
  end
end
