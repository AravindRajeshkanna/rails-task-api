# Publishes domain events through Rails 8.1's structured event reporter
# (Rails.event). Subscribers in app/subscribers fan them out to logs, Action
# Cable and webhooks, so models never know who is listening.
#
# Models call +queue_event+ from in-transaction callbacks (after_create /
# after_update). Events are published only once the transaction commits, and are
# dropped on rollback, so subscribers never hear about changes that didn't happen.
# Queueing from after_update (rather than reacting in after_update_commit) also
# means `touch` from a child record doesn't masquerade as an update.
#
# Including models implement +event_project_id+.
module EventEmitting
  extend ActiveSupport::Concern

  included do
    after_commit :publish_queued_events
    after_rollback :discard_queued_events
  end

  private
    def queue_event(verb)
      @queued_events ||= []
      @queued_events << verb unless @queued_events.include?(verb)
    end

    def publish_queued_events
      verbs, @queued_events = @queued_events, nil
      verbs&.each { |verb| emit_event(verb) }
    end

    def discard_queued_events
      @queued_events = nil
    end

    def emit_event(verb)
      Rails.event.notify(
        "#{self.class.model_name.singular}.#{verb}",
        subject: to_global_id.to_s,
        project_id: event_project_id,
        actor_id: Current.user&.id
      )
    end
end
