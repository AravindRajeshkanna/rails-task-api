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

      OutboxEvent.insert({ event_id: envelope[:id], event_type: name, payload: envelope, created_at: Time.current }, unique_by: :event_id) # rubocop:disable Rails/SkipsModelValidations -- ON CONFLICT DO NOTHING is the point
      ActiveRecord::Base.connection.current_transaction.after_commit { OutboxRelayJob.wake }
    end
  end
end
