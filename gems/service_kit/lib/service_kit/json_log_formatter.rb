require "json"
require "logger"

module ServiceKit
  # One JSON object per line. A Hash message becomes top-level fields (structured events, CloudWatch EMF
  # lines); the active OpenTelemetry trace ids are added so a log line links to its trace.
  class JsonLogFormatter < ::Logger::Formatter
    include ActiveSupport::TaggedLogging::Formatter

    RESERVED = %i[time level request_id progname].freeze
    REQUEST_LOG_NOISE = /\A(Started [A-Z]+ "|Processing by |Completed \d{3} |\s+Parameters: |\s*rescue_from )/

    def initialize(service: nil)
      super()
      @service = service
    end

    def call(severity, time, progname, message)
      return "" if message.is_a?(String) && message.match?(REQUEST_LOG_NOISE)

      entry = { time: time.utc.iso8601(3), level: severity, service: @service, request_id: current_tags.first, progname: progname }
      entry.merge!(trace_fields)
      entry.merge!(message.is_a?(Hash) ? message.except(*RESERVED) : { message: message.is_a?(String) ? message : message.inspect })
      "#{entry.compact.to_json}\n"
    end

    private
      def trace_fields
        context = OpenTelemetry::Trace.current_span.context
        context.valid? ? { trace_id: context.hex_trace_id, span_id: context.hex_span_id } : {}
      end
  end
end
