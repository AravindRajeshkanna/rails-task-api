module Observability
  # Thin helpers over the OpenTelemetry API. When the SDK is not configured (tests, local development)
  # the API hands back no-op tracers, so calling these costs nothing and never fails.
  module Tracing
    TRACER_NAME = "task-api"

    extend self

    # Tests inject a provider with an in-memory exporter. (The global OpenTelemetry.tracer_provider can
    # only be set once per process, so swapping it between examples would not work.)
    attr_writer :tracer_provider

    def tracer = (@tracer_provider || OpenTelemetry.tracer_provider).tracer(TRACER_NAME)

    def in_span(name, attributes: {}, &block) = tracer.in_span(name, attributes: attributes, &block)

    # The active trace as hex ids, for correlating a log line with a trace. nil when not tracing.
    def current_ids
      context = OpenTelemetry::Trace.current_span.context
      return unless context.valid?

      { trace_id: context.hex_trace_id, span_id: context.hex_span_id }
    end

    # Adds low-cardinality identity attributes to the request's server span.
    def annotate_request(user_id: nil)
      span = OpenTelemetry::Trace.current_span
      span.set_attribute("enduser.id", user_id.to_s) if user_id && span.recording?
    end
  end
end
