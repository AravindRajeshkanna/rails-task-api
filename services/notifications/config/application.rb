require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "action_mailer/railtie"

Bundler.require(*Rails.groups)

# The Notification service: consumes domain events from SQS and tells people about them (email, Slack).
# It owns no business data. Every event carries what the message needs, so it never calls back.
module NotificationsService
  class Application < Rails::Application
    config.load_defaults 8.1
    config.api_only = true
    config.autoload_lib(ignore: %w[assets tasks puma])
    config.service_kit.name = "notifications-service"
    config.service_kit.collectors = [ -> { Notifications::Metrics.collect! } ]

    config.x.queue_url = ENV["NOTIFICATIONS_QUEUE_URL"]
    config.x.slack_webhook_url = ENV["SLACK_WEBHOOK_URL"]
    config.x.slack_events = ENV.fetch("SLACK_EVENTS", "task.completed").split(",").map(&:strip)
    config.action_mailer.default_options = { from: ENV.fetch("MAIL_FROM", "Task API <no-reply@example.com>") }
  end
end
