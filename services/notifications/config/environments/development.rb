require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.enable_reloading = true
  config.eager_load = false
  config.consider_all_requests_local = true
  config.server_timing = true
  config.action_mailer.delivery_method = :smtp
  config.action_mailer.smtp_settings = { address: ENV.fetch("SMTP_ADDRESS", "localhost"), port: Integer(ENV.fetch("SMTP_PORT", 1025)) } # Mailpit
  config.action_mailer.raise_delivery_errors = false
  config.cache_store = :memory_store
  config.active_support.deprecation = :log
  config.action_controller.raise_on_missing_callback_actions = true
end
