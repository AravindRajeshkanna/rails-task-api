# Wires Rails 8.1 structured events (Rails.event) to their subscribers.
# Models only call `emit_event`; see app/models/concerns/event_emitting.rb.
#
# Subscriptions are made once at boot. In development, restart the server after
# editing a subscriber (code reloading does not re-subscribe).
Rails.application.config.after_initialize do
  # Log our domain and AI events, the access log and job outcomes. Rails emits many more framework events
  # (every SQL statement, every render); those stay out of the logs.
  Rails.event.subscribe(Events::LogSubscriber.new) { |event| Events::LogSubscriber::LOGGED.match?(event[:name]) }

  Rails.event.subscribe(Events::MetricsSubscriber.new)

  # Events for the other services do not go through here: they are written to the transactional outbox, inside
  # the transaction of the change, and sent by OutboxRelayJob (see Events::Outbox).

  # The in-app inbox, fed by the events people should hear about.
  Rails.event.subscribe(Events::InboxSubscriber.new) { |event| Events::InboxSubscriber::HANDLED.include?(event[:name]) }

  Rails.event.subscribe(Events::BroadcastSubscriber.new) do |event|
    event[:name].start_with?("task.", "comment.", "project.")
  end

  Rails.event.subscribe(Events::WebhookSubscriber.new) do |event|
    Webhook::EVENTS.include?(event[:name])
  end

  # Every KMS request the encryption keys cause (kms_encryption gem): a metric for each, and a log line for the ones that failed.
  ActiveSupport::Notifications.subscribe("request.kms_encryption") do |event|
    outcome = event.payload[:outcome].to_s
    Rails.event.notify(outcome == "ok" ? "kms.request" : "kms.failed", operation: event.payload[:operation], outcome: outcome, duration_ms: event.duration.round(1))
  end

  Observability::Metrics::BUILD_INFO.set(1, labels: { version: ENV.fetch("APP_VERSION", "dev"), ruby: RUBY_VERSION, rails: Rails.version })
end
