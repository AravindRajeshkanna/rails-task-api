require "active_support"
require "active_support/core_ext"
require "active_support/tagged_logging"
require "opentelemetry/sdk"

require_relative "service_kit/version"
require_relative "service_kit/jwt_verifier"
require_relative "service_kit/json_log_formatter"
require_relative "service_kit/metrics"
require_relative "service_kit/railtie" if defined?(Rails::Railtie)

# Shared plumbing for the Task API services. Required explicitly in each service's Gemfile.
module ServiceKit
end
