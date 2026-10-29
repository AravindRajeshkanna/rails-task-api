# Error tracking. Inert unless SENTRY_DSN is set, so development, test and CI never report.
# Rails.error.report(...) calls and unhandled exceptions are captured by sentry-rails.
if ENV["SENTRY_DSN"].present?
  Sentry.init do |config|
    config.dsn = ENV["SENTRY_DSN"]
    config.environment = ENV.fetch("SENTRY_ENVIRONMENT", Rails.env)
    config.release = ENV["APP_VERSION"]
    config.breadcrumbs_logger = %i[active_support_logger http_logger]
    config.send_default_pii = false
    config.traces_sample_rate = ENV.fetch("SENTRY_TRACES_SAMPLE_RATE", "0.0").to_f
    config.excluded_exceptions += %w[Pundit::NotAuthorizedError Authentication::NotAuthenticated]
  end
end
