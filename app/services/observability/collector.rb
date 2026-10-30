module Observability
  # Refreshes the gauges that describe current state (queue backlog, connection pool). Called on each
  # scrape, but at most every TTL seconds, so a busy Prometheus cannot hammer the database.
  module Collector
    TTL = 15
    MUTEX = Mutex.new
    @refreshed_at = nil
    @queues = Set.new

    class << self
      def refresh!(now: Process.clock_gettime(Process::CLOCK_MONOTONIC))
        MUTEX.synchronize do
          return if @refreshed_at && now - @refreshed_at < TTL

          @refreshed_at = now
          collect_db_pool
          collect_queue
          collect_outbox
        end
      end

      # Tests (and the console) can force the next scrape to re-read everything.
      def reset!
        MUTEX.synchronize { @refreshed_at = nil }
      end

      private
        def collect_db_pool
          Metrics::DB_POOL.tap do |gauge|
            ActiveRecord::Base.connection_pool.stat.slice(:size, :connections, :busy, :idle, :waiting)
              .each { |state, value| gauge.set(value, labels: { state: state.to_s }) }
          end
        rescue => error
          failed("db_pool", error)
        end

        def collect_queue
          snapshot = QueueStats.snapshot or return

          # A queue that drained since the last scrape must read 0, not its stale value.
          (@queues | snapshot.ready.keys).each do |queue|
            Metrics::QUEUE_READY.set(snapshot.ready.fetch(queue, 0), labels: { queue: queue })
            Metrics::QUEUE_OLDEST_AGE.set(snapshot.oldest_age.fetch(queue, 0), labels: { queue: queue })
          end
          @queues = Set.new(snapshot.ready.keys)

          Metrics::QUEUE_CLAIMED.set(snapshot.claimed)
          Metrics::QUEUE_SCHEDULED.set(snapshot.scheduled)
          Metrics::QUEUE_FAILED.set(snapshot.failed)
          Metrics::QUEUE_WORKERS.set(snapshot.workers)
        rescue => error
          failed("queue", error)
        end

        def collect_outbox
          pending = OutboxEvent.pending
          oldest = pending.minimum(:created_at)
          Metrics::OUTBOX_PENDING.set(pending.count)
          Metrics::OUTBOX_OLDEST_AGE.set(oldest ? (Time.current - oldest).to_i : 0)
          Metrics::OUTBOX_FAILING.set(pending.where("attempts > 0").count)
        rescue => error
          failed("outbox", error)
        end

        def failed(collector, error)
          Metrics::COLLECTOR_ERRORS.increment(labels: { collector: collector })
          Rails.logger.warn("metrics collector #{collector} failed: #{error.class}: #{error.message}")
        end
    end
  end
end
