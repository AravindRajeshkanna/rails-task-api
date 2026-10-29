# Wires Rails 8.1 structured events (Rails.event) to their subscribers.
# Models only call `emit_event`; see app/models/concerns/event_emitting.rb.
#
# Subscriptions are made once at boot. In development, restart the server after
# editing a subscriber (code reloading does not re-subscribe).
Rails.application.config.after_initialize do
  Rails.event.subscribe(Events::LogSubscriber.new)

  Rails.event.subscribe(Events::BroadcastSubscriber.new) do |event|
    event[:name].start_with?("task.", "comment.", "project.")
  end

  Rails.event.subscribe(Events::WebhookSubscriber.new) do |event|
    Webhook::EVENTS.include?(event[:name])
  end
end
