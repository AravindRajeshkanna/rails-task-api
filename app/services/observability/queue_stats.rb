module Observability
  # A snapshot of Solid Queue's backlog, read from its tables. Reading the database (rather than
  # counting events in each worker process) gives one consistent, process-independent answer that
  # autoscalers and alerts can trust. Returns nil where the queue tables do not exist.
  module QueueStats
    Snapshot = Struct.new(:ready, :oldest_age, :claimed, :scheduled, :failed, :workers, keyword_init: true) do
      def total_ready = ready.values.sum
      def max_age = oldest_age.values.max.to_f
    end

    def self.snapshot(now: Time.current)
      return unless SolidQueue::ReadyExecution.table_exists?

      oldest = SolidQueue::ReadyExecution.group(:queue_name).minimum(:created_at)
      Snapshot.new(
        ready: SolidQueue::ReadyExecution.group(:queue_name).count,
        oldest_age: oldest.transform_values { |created_at| [ now - created_at, 0 ].max.round(1) },
        claimed: SolidQueue::ClaimedExecution.count,
        scheduled: SolidQueue::ScheduledExecution.count,
        failed: SolidQueue::FailedExecution.count,
        workers: SolidQueue::Process.where(kind: "Worker").count
      )
    end
  end
end
