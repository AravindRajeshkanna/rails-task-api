require "rails/railtie"

module ServiceKit
  # Gives every service the same operational surface with no per-service code:
  #   * JSON logs (production, or LOG_FORMAT=json) with trace ids, and structured access logs
  #   * request id/user context on Rails.event
  #   * GET /metrics (Prometheus) and HTTP request metrics
  #   * OpenTelemetry tracing to OTEL_EXPORTER_OTLP_ENDPOINT (X-Ray compatible ids and propagation)
  class Railtie < Rails::Railtie
    config.service_kit = ActiveSupport::OrderedOptions.new

    # Request id on every event emitted while a request is handled.
    class EventContext
      def initialize(app) = @app = app

      def call(env)
        Rails.event.set_context(request_id: env["action_dispatch.request_id"])
        @app.call(env)
      ensure
        Rails.event.clear_context
      end
    end

    initializer "service_kit.middleware" do |app|
      app.middleware.insert_after ActionDispatch::RequestId, EventContext
      app.middleware.insert_after EventContext, Metrics::Endpoint, collectors: app.config.service_kit.collectors || []
    end

    initializer "service_kit.logging", before: :initialize_logger do |app|
      json = ENV["LOG_FORMAT"] == "json" || (Rails.env.production? && ENV.fetch("LOG_FORMAT", "json") == "json")
      app.config.service_kit.json_logs = json
    end

    config.after_initialize do |app|
      if app.config.service_kit.json_logs
        Rails.logger.formatter = JsonLogFormatter.new(service: app.config.service_kit.name || ENV["OTEL_SERVICE_NAME"])
      end

      Metrics.http_requests # register now, so /metrics lists them (at zero) before the first request
      Metrics.http_duration
      Rails.event.subscribe(Metrics::Subscriber.new)
      Rails.event.subscribe(StructuredLog.new(app.config.service_kit.json_logs)) { |event| StructuredLog::LOGGED.match?(event[:name]) }
    end

    # Domain-neutral event logging: the access log and job outcomes, plus anything a service names in LOGGED_EVENTS.
    class StructuredLog
      LOGGED = /\Aaction_controller\.(request_completed|rescue_from_handled)\z|\Aactive_job\.(completed|failed|discarded|retry_stopped)\z|\A(auth|notification|ai)\./

      def initialize(json) = @json = json

      def emit(event)
        fields = event[:payload].merge(event[:context] || {})
        if @json
          Rails.logger.info({ event: event[:name] }.merge(fields))
        else
          Rails.logger.info("event=#{event[:name]} #{fields.map { |key, value| "#{key}=#{value}" }.join(' ')}")
        end
      end
    end

    initializer "service_kit.tracing", before: :load_config_initializers do
      if ENV["OTEL_EXPORTER_OTLP_ENDPOINT"].to_s != "" && ENV["OTEL_SDK_DISABLED"] != "true" && !Rails.env.test?
        require "opentelemetry/sdk"
        require "opentelemetry/exporter/otlp"
        require "opentelemetry/propagator/xray"
        require "opentelemetry/instrumentation/rails"
        require "opentelemetry/instrumentation/rack"
        require "opentelemetry/instrumentation/pg"
        require "opentelemetry/instrumentation/net/http"
        require "opentelemetry/instrumentation/aws_sdk"

        ENV["OTEL_PROPAGATORS"] ||= "tracecontext,baggage,xray"
        ENV["OTEL_TRACES_SAMPLER"] ||= "parentbased_traceidratio"
        ENV["OTEL_TRACES_SAMPLER_ARG"] ||= "0.1"

        OpenTelemetry::SDK.configure do |c|
          c.service_name = ENV.fetch("OTEL_SERVICE_NAME", "task-api-service")
          c.service_version = ENV.fetch("APP_VERSION", "dev")
          c.id_generator = OpenTelemetry::Propagator::XRay::IDGenerator
          c.use "OpenTelemetry::Instrumentation::Rack", untraced_endpoints: [ "/up", "/metrics" ]
          c.use "OpenTelemetry::Instrumentation::Rails"
          c.use "OpenTelemetry::Instrumentation::PG", db_statement: :obfuscate
          c.use "OpenTelemetry::Instrumentation::Net::HTTP"
          c.use "OpenTelemetry::Instrumentation::AwsSdk"
        end
      end
    end
  end
end
