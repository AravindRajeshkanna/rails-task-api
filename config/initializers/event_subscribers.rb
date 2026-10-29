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

  # Publish domain events for the other services when a topic is configured (EVENTS_SNS_TOPIC_ARN).
  if Rails.configuration.x.events.sns_topic_arn.present?
    Rails.event.subscribe(Events::SnsSubscriber.new) { |event| event[:name].match?(/\A(task|project|comment)\./) }
  end

  # The in-app inbox, fed by the events people should hear about.
  Rails.event.subscribe(Events::InboxSubscriber.new) { |event| Events::InboxSubscriber::HANDLED.include?(event[:name]) }

  Rails.event.subscribe(Events::BroadcastSubscriber.new) do |event|
    event[:name].start_with?("task.", "comment.", "project.")
  end

  Rails.event.subscribe(Events::WebhookSubscriber.new) do |event|
    Webhook::EVENTS.include?(event[:name])
  end

  Observability::Metrics::BUILD_INFO.set(1, labels: { version: ENV.fetch("APP_VERSION", "dev"), ruby: RUBY_VERSION, rails: Rails.version })
end
