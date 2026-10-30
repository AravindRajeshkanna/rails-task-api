# Publishes domain events through Rails 8.1's structured event reporter
# (Rails.event). Subscribers in app/subscribers fan them out to logs, Action
# Cable and webhooks, so models never know who is listening.
#
# Models call +queue_event+ from in-transaction callbacks (after_create /
# after_update). Local subscribers (logs, Action Cable, webhooks, the inbox) hear about it only once
# the transaction commits, and never about a rollback. Queueing from after_update (rather than reacting in
# after_update_commit) also means `touch` from a child record doesn't masquerade as an update.
#
# The same call writes the event to the transactional outbox (Events::Outbox), inside the transaction, which
# is what the other services are fed from. Its envelope is built right then, so it must be called after the
# record's associations are saved. Declare the callbacks that call +queue_event+ after the associations in the
# model (callbacks run in the order they are declared), and as after_save when the model has Active Storage
# attachments, which are saved in after_save (see Task). outbox_spec checks that tags and attachments are in.
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
      return if @queued_events.include?(verb)

      @queued_events << verb
      Events::Outbox.record("#{self.class.model_name.singular}.#{verb}", subject: self, project_id: event_project_id, actor_id: Current.user&.id)
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
