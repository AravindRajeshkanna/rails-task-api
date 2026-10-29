# Distributed tracing with OpenTelemetry, exported over OTLP. In EKS the endpoint is the ADOT collector
# (a DaemonSet or sidecar) whose awsxray exporter delivers traces to AWS X-Ray; locally it can be any
# OTLP backend (docker compose ships a collector and Jaeger).
#
# Off unless OTEL_EXPORTER_OTLP_ENDPOINT is set, so development, tests and CI are unaffected. Standard
# OTEL_* variables apply: OTEL_SERVICE_NAME, OTEL_TRACES_SAMPLER(_ARG), OTEL_RESOURCE_ATTRIBUTES, ...
if ENV["OTEL_EXPORTER_OTLP_ENDPOINT"].present? && ENV["OTEL_SDK_DISABLED"] != "true" && !Rails.env.test?
  require "opentelemetry/sdk"
  require "opentelemetry/exporter/otlp"
  require "opentelemetry/propagator/xray"
  require "opentelemetry/instrumentation/rails"
  require "opentelemetry/instrumentation/rack"
  require "opentelemetry/instrumentation/pg"
  require "opentelemetry/instrumentation/net/http"
  require "opentelemetry/instrumentation/aws_sdk"

  # Accept and emit W3C trace context (service to service), baggage, and X-Ray headers (ALB, API Gateway, Lambda).
  ENV["OTEL_PROPAGATORS"] ||= "tracecontext,baggage,xray"
  # Sample a fraction of new traces, but always follow the caller's decision.
  ENV["OTEL_TRACES_SAMPLER"] ||= "parentbased_traceidratio"
  ENV["OTEL_TRACES_SAMPLER_ARG"] ||= "0.1"

  OpenTelemetry::SDK.configure do |config|
    config.service_name = ENV.fetch("OTEL_SERVICE_NAME", "task-api")
    config.service_version = ENV.fetch("APP_VERSION", "dev")
    # X-Ray rejects trace ids that do not start with a recent epoch timestamp.
    config.id_generator = OpenTelemetry::Propagator::XRay::IDGenerator

    config.use "OpenTelemetry::Instrumentation::Rack", untraced_endpoints: [ "/up", "/metrics" ]
    config.use "OpenTelemetry::Instrumentation::Rails"
    config.use "OpenTelemetry::Instrumentation::PG", db_statement: :obfuscate
    config.use "OpenTelemetry::Instrumentation::Net::HTTP"
    config.use "OpenTelemetry::Instrumentation::AwsSdk"
  end
end
