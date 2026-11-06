module ServiceKit
  # OpenTelemetry for a Rails application, in one place: the Task API and the three services call it from an initializer, so that they cannot differ.
  # Off unless OTEL_EXPORTER_OTLP_ENDPOINT is set, so development, tests and CI are unaffected. The standard OTEL_* variables apply (OTEL_SERVICE_NAME,
  # OTEL_TRACES_SAMPLER(_ARG), OTEL_RESOURCE_ATTRIBUTES, ...).
  module Tracing
    # Not served, so a probe every few seconds is not a trace every few seconds.
    UNTRACED_ENDPOINTS = [ "/up", "/metrics" ].freeze

    module_function

    def enabled? = ENV["OTEL_EXPORTER_OTLP_ENDPOINT"].to_s != "" && ENV["OTEL_SDK_DISABLED"] != "true" && !Rails.env.test?

    # Call from an initializer, before the application's middleware stack is built: the ActionPack instrumentation adds the Rack middleware to it.
    def configure(default_service_name:)
      require_instrumentation
      set_defaults

      OpenTelemetry::SDK.configure do |config|
        config.service_name = ENV.fetch("OTEL_SERVICE_NAME", default_service_name)
        config.service_version = ENV.fetch("APP_VERSION", "dev")
        # X-Ray rejects trace ids that do not start with a recent epoch timestamp.
        config.id_generator = OpenTelemetry::Propagator::XRay::IDGenerator

        config.use "OpenTelemetry::Instrumentation::Rack", untraced_endpoints: UNTRACED_ENDPOINTS.dup # the instrumentation edits the array it is given
        # What traces a request in a Rails application: its Railtie adds the Rack middleware to the stack (Rack alone only configures it) and the span is named for
        # the route (GET /api/v1/projects/:id) and not for the address. Until this was added, the tracing reported "successfully installed" and no request was
        # traced: no server span, no trace id on any log line, and an AI service without a database seemed to send nothing at all. The "Rails" instrumentation
        # that stood here is a shortcut whose own initializer is skipped when it is required this late (spec/tracing_spec.rb boots an application to hold all this).
        config.use "OpenTelemetry::Instrumentation::ActionPack"
        config.use "OpenTelemetry::Instrumentation::PG", db_statement: :obfuscate
        config.use "OpenTelemetry::Instrumentation::Net::HTTP"
        config.use "OpenTelemetry::Instrumentation::AwsSdk"
      end
    end

    def require_instrumentation
      require "opentelemetry/sdk"
      require "opentelemetry/exporter/otlp"
      require "opentelemetry/propagator/xray"
      require "opentelemetry/instrumentation/rack"
      require "opentelemetry/instrumentation/action_pack"
      require "opentelemetry/instrumentation/pg"
      require "opentelemetry/instrumentation/net/http"
      require "opentelemetry/instrumentation/aws_sdk"
    end

    def set_defaults
      # Accept and emit W3C trace context (service to service), baggage, and X-Ray headers (ALB, API Gateway, Lambda).
      ENV["OTEL_PROPAGATORS"] ||= "tracecontext,baggage,xray"
      # Sample a fraction of new traces, but always follow the caller's decision.
      ENV["OTEL_TRACES_SAMPLER"] ||= "parentbased_traceidratio"
      ENV["OTEL_TRACES_SAMPLER_ARG"] ||= "0.1"
    end
  end
end
