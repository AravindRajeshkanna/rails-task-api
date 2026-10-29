require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false
  config.assume_ssl = ENV.fetch("ASSUME_SSL", "true") == "true"
  config.force_ssl = ENV.fetch("FORCE_SSL", "false") == "true" # TLS ends at the ALB; the pod speaks HTTP
  config.log_tags = [ :request_id ]
  config.logger = ActiveSupport::TaggedLogging.logger(STDOUT)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")
  config.silence_healthcheck_path = "/up"
  config.active_support.report_deprecations = false
  config.cache_store = :memory_store, { size: 16.megabytes }
  config.i18n.fallbacks = true

  # Calls arrive by service name from inside the cluster; the probes use the pod IP.
  allowed_hosts = ENV.fetch("ALLOWED_HOSTS", "").split(",").map(&:strip).compact_blank
  config.hosts = allowed_hosts if allowed_hosts.any?
  config.host_authorization = { exclude: ->(request) { request.path.in?(%w[/up /metrics]) } }
end
