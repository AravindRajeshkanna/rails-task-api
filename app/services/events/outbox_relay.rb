module Events
  # Sends pending outbox events to SNS, oldest first, in batches, for up to TIME_BUDGET. Run by OutboxRelayJob
  # (woken after each commit, and swept every minute in case a wake-up was missed).
  #
  # An event that cannot be sent stays in the outbox with a growing delay and its last error; one bad event
  # never holds up the others. Nothing is ever dropped: the alarm is the age of the oldest pending event.
  class OutboxRelay
    BATCH = 50
    LEASE = 2.minutes
    TIME_BUDGET = 20.seconds

    def self.call = new.call

    # Returns how many events were published.
    def call
      return 0 unless Outbox.enabled?

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TIME_BUDGET
      published = 0
      loop do
        batch = OutboxEvent.claim(limit: BATCH, lease: LEASE)
        break if batch.empty?

        published += batch.count { |event| deliver(event) }
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline # always at least one batch
      end
      published
    end

    private
      def deliver(event)
        SnsPublisher.publish(event.payload)
        event.mark_published!
        true
      rescue => error
        event.mark_failed!(error)
        Rails.error.report(error, handled: true, severity: :warning, context: { outbox_event: event.event_id, type: event.event_type, attempts: event.attempts })
        false
      end
  end
end
