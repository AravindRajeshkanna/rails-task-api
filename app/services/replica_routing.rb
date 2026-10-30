# Serving reads from a read replica, without anyone reading a change they made a moment ago from a replica that has not seen it yet (ADR 60).
#
# A replica is a copy that trails the primary by a little (milliseconds on Aurora, more under load). That is fine for a list someone else's work
# changed, and wrong for a list the person just changed themselves. So:
#
#   * only actions that opt in (`replica_reads :index`) are routed, and only GET and HEAD;
#   * whoever wrote anything in the last few seconds (config.x.replica_read_your_writes_seconds) is served by the primary: read-your-writes;
#   * if the replica cannot be reached, the request is served by the primary instead, and after three failures in a row the replica is not tried for a while
#     (a circuit breaker), so a dead replica costs a few requests a retry and then nothing.
#
# Everything else about the replica is the database's job; with no replica configured (DB_REPLICA_HOST unset) none of this runs and every read is the primary's.
module ReplicaRouting
  # The replica itself is unreachable or its pool is exhausted: try the primary.
  UNREACHABLE = [ ActiveRecord::ConnectionNotEstablished, ActiveRecord::ConnectionFailed, ActiveRecord::ConnectionTimeoutError ].freeze
  # PostgreSQL cancels a long query on a replica when it conflicts with replaying the primary's changes: not the replica being down, but this query cannot finish there.
  RECOVERY_CONFLICT = [ ActiveRecord::SerializationFailure, ActiveRecord::QueryCanceled ].freeze

  module_function

  def enabled? = Rails.configuration.x.replica_reads

  def window = Rails.configuration.x.replica_read_your_writes_seconds

  def note_write(user_id)
    Rails.cache.write(marker(user_id), true, expires_in: window.seconds)
  end

  def wrote_recently?(user_id) = Rails.cache.exist?(marker(user_id))

  def breaker = ServiceKit::CircuitBreaker.for(:replica, failure_threshold: 3, window: 30, reset_timeout: 15, max_reset_timeout: 120, exceptions: UNREACHABLE)

  # Runs the block (the rest of the request) on the replica, or on the primary, and says which in a metric.
  def route(request, user_id, &block)
    return yield unless enabled? && (request.get? || request.head?)
    return primary(:read_your_writes, &block) if user_id && wrote_recently?(user_id)

    on_replica(&block)
  end

  def on_replica(&block)
    result = breaker.call { ApplicationRecord.connected_to(role: :reading, &block) }
    count(:replica)
    result
  rescue ServiceKit::CircuitBreaker::OpenError
    primary(:breaker_open, &block)
  rescue *UNREACHABLE
    primary(:replica_unreachable, &block)
  rescue *RECOVERY_CONFLICT
    primary(:recovery_conflict, &block)
  end

  def primary(reason, &block)
    count(reason)
    yield
  end

  def count(outcome) = Observability::Metrics::REPLICA_READS.increment(labels: { outcome: outcome.to_s })

  def marker(user_id) = "replica:wrote:#{user_id}"
end
