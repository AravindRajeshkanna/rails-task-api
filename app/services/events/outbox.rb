module Events
  # Writing to the transactional outbox: the one way events reach the other services.
  #
  #   Events::Outbox.record("task.created", subject: task, project_id: task.project_id, actor_id: 5)
  #
  # Call it inside the transaction of the change it describes (EventEmitting does, for model events): the row
  # commits or rolls back with the change, so there is never an event without a change or a change without
  # an event. The envelope is built here, at that moment. Outside a transaction it is just one insert.
  #
  # Does nothing unless EVENTS_SNS_TOPIC_ARN is set, so single-host installs write no rows nobody reads.
  module Outbox
    ROUTED = /\A(task|project|comment)\./

    module_function

    def enabled? = Rails.configuration.x.events.sns_topic_arn.present?

    # +id+ makes an event idempotent: recording the same id twice stores it once (the daily reminder uses this).
    def record(name, subject:, project_id:, actor_id: nil, id: nil)
      return unless enabled? && ROUTED.match?(name)

      event = {
        name: name, timestamp: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond),
        payload: { subject: subject.to_global_id.to_s, project_id: project_id, actor_id: actor_id }
      }
      envelope = CloudEvent.build(event, **{ id: id }.compact) or return

      write(envelope)
    end

    # A person's erasure (AccountErasure, ADR 79), for the services that hold something of theirs: the Auth service deletes the identity it holds under
    # +auth_subject+, the Notification service the deliveries it logged for +user_id+. Not a model event (the subject is a tombstone by the time anyone reads
    # it), so the envelope is made here, and it carries two ids and **not the address**: an event about forgetting someone must not be the newest copy of them.
    # The id is the person's, so recording it twice stores it once.
    def record_erasure(user, auth_subject:)
      return unless enabled?

      write(erasure_envelope(user, auth_subject: auth_subject))
    end

    # Also what `bin/rails erasure:publish` sends again (docs/runbooks/account-erasure.md).
    def erasure_envelope(user, auth_subject:)
      {
        specversion: "1.0", id: "user.erased:#{user.id}", source: CloudEvent::SOURCE, type: "user.erased", time: Time.current.utc.iso8601(3),
        datacontenttype: "application/json", subject: user.to_global_id.to_s, data: { user_id: user.id, auth_subject: auth_subject }.compact
      }
    end

    def write(envelope)
      OutboxEvent.insert({ event_id: envelope[:id], event_type: envelope[:type], payload: envelope, created_at: Time.current }, unique_by: :event_id) # rubocop:disable Rails/SkipsModelValidations -- ON CONFLICT DO NOTHING is the point
      ActiveRecord::Base.connection.current_transaction.after_commit { OutboxRelayJob.wake }
    end
    private_class_method :write
  end
end
