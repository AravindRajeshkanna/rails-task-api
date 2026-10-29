# One JSON object per log line in production (set LOG_FORMAT=plain to opt out), so
# log shippers can index request ids, levels and messages without regexes.
class JsonLogFormatter < ::Logger::Formatter
  include ActiveSupport::TaggedLogging::Formatter

  def call(severity, time, progname, message)
    entry = {
      time: time.utc.iso8601(3),
      level: severity,
      request_id: current_tags.first,
      progname: progname,
      message: message.is_a?(String) ? message : message.inspect
    }.compact

    "#{entry.to_json}\n"
  end
end

if Rails.env.production? && ENV.fetch("LOG_FORMAT", "json") == "json"
  Rails.logger.formatter = JsonLogFormatter.new
end
