# One JSON object per log line in production (set LOG_FORMAT=plain to opt out, or LOG_FORMAT=json to
# force it in any environment), so log shippers can index request ids, levels and fields without regexes.
#
# A Hash passed to the logger becomes fields of the JSON object. That is how domain events, the access
# log (action_controller.request_completed) and CloudWatch EMF metric lines get their own top-level keys.
# When a trace is active the line carries trace_id/span_id, so a log line links to its trace.
class JsonLogFormatter < ::Logger::Formatter
  include ActiveSupport::TaggedLogging::Formatter

  RESERVED = %i[time level request_id progname].freeze
  # Rails' multi-line text request log. The structured action_controller.request_completed event
  # replaces it, so these lines are dropped rather than logged twice.
  REQUEST_LOG_NOISE = /\A(Started [A-Z]+ "|Processing by |Completed \d{3} |\s+Parameters: |\s*rescue_from )/

  def call(severity, time, progname, message)
    return "" if message.is_a?(String) && message.match?(REQUEST_LOG_NOISE)

    entry = { time: time.utc.iso8601(3), level: severity, request_id: current_tags.first, progname: progname }
    entry.merge!(trace_fields)
    entry.merge!(message.is_a?(Hash) ? message.except(*RESERVED) : { message: message.is_a?(String) ? message : message.inspect })

    "#{entry.compact.to_json}\n"
  end

  private
    def trace_fields
      span = OpenTelemetry::Trace.current_span.context
      span.valid? ? { trace_id: span.hex_trace_id, span_id: span.hex_span_id } : {}
    end
end

json_logs = ENV["LOG_FORMAT"] == "json" || (Rails.env.production? && ENV.fetch("LOG_FORMAT", "json") == "json")
Rails.application.config.x.json_logs = json_logs

Rails.logger.formatter = JsonLogFormatter.new if json_logs
