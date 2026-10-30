# Read-only mode: while the database cannot take writes, reads keep working and every write gets a clear, retryable
# 503 `read_only` instead of a 500.
#
# That happens in two situations (docs/runbooks/regional-failover.md):
#   * the standby region's database is a read-only replica until it is promoted, and traffic can reach it
#     before that (DNS fails over by itself; promoting the database is a human step);
#   * an operator wants writes drained before a planned switchover: READ_ONLY=true refuses them up front,
#     without touching the database at all.
#
# Defined here, not under app/, because middleware must exist before application code can be autoloaded.
module ReadOnlyMode
  RETRY_AFTER = 30 # seconds: a promotion takes minutes, and a client that retries every 30 s is no load

  # Did this error come from the database refusing a write? Either Active Record's own check (READ_ONLY=true prevents
  # the write before it is sent) or Postgres answering SQLSTATE 25006 (a replica, or a writer that was just demoted).
  def self.error?(error)
    error.is_a?(ActiveRecord::ReadOnlyError) ||
      (error.is_a?(ActiveRecord::StatementInvalid) && error.cause.is_a?(PG::ReadOnlySqlTransaction))
  end

  def self.enforced? = Rails.configuration.x.read_only

  class Middleware
    def initialize(app) = @app = app

    def call(env)
      return @app.call(env) unless ReadOnlyMode.enforced?

      # Per request (the setting is thread- and fiber-local). It covers every database, so a request cannot enqueue a job either;
      # only the cache is exempt, below.
      ActiveRecord::Base.while_preventing_writes { @app.call(env) }
    rescue StandardError => error
      raise unless ReadOnlyMode.error?(error)

      refuse(env, error)
    end

    private
      # The same envelope as every other error (ErrorSerializer). A request that had changed anything was rolled back
      # with the exception, so the client can retry it as it is.
      def refuse(env, error)
        source = error.is_a?(ActiveRecord::ReadOnlyError) ? "switch" : "database"
        Rails.event.notify("read_only.refused", source: source, method: env["REQUEST_METHOD"])

        body = ErrorSerializer.new(
          status: :service_unavailable, code: "read_only", request_id: env["action_dispatch.request_id"],
          message: "The service is read-only right now (a database promotion or maintenance is under way). Reads still work; retry this change shortly."
        )
        [ 503, { "content-type" => "application/json; charset=utf-8", "retry-after" => RETRY_AFTER.to_s, "cache-control" => "no-store" }, [ body.to_json ] ]
      end
  end

  # Solid Cache gives up quietly on transient database errors so that a cache problem never takes a request down, but a read-only
  # database is not on its list: every cache write (rate-limit counters, cached project statistics) would raise and fail reads too. Treat it
  # the same way: the write is skipped, the read is a miss. (Throttling counters stop counting while it lasts; the WAF's rate rule still applies.)
  module CacheTolerance
    private
      def failsafe(method, returning: nil)
        super
      rescue ActiveRecord::StatementInvalid, ActiveRecord::ReadOnlyError => error
        raise unless ReadOnlyMode.error?(error)

        error_handler&.call(method: method, exception: error, returning: returning)
        returning
      end
  end
end

Rails.application.config.middleware.use ReadOnlyMode::Middleware

# The cache is Solid Cache in production only; the other environments never load it.
SolidCache::Store.prepend(ReadOnlyMode::CacheTolerance) if defined?(SolidCache::Store)
