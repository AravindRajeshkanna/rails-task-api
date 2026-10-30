# Load shedding (ADR 62). When every Puma thread is busy and requests are already queueing for one, taking more work only makes everyone slower: a queue that
# grows without bound turns into timeouts for requests that would have been fast. Better to refuse the work that is most expensive and easiest for a client
# to retry, at once, with a Retry-After, and keep serving what is cheap and what matters.
#
#   shed first   search, analytics, the activity feed, audit logs, GraphQL, AI: the endpoints that cost the most per request
#   never shed   health checks, metrics, sign-in, and every write (a refused write is lost work for the client; a refused read is a retry)
#
# The signal is the backlog of the Puma thread pool: requests accepted but still waiting for a thread. It is read from Puma when running under it, and
# there is no signal (nothing is shed) anywhere else, rather than a guess. Defined here, not under app/, because middleware must exist before application
# code can be autoloaded.
class LoadShedder
  EXPENSIVE = %r{\A/api/v1/(search|activity|graphql)\b|/(analytics|audit_events|summary)\z|\A/api/v1/ai/}

  # Puma's own numbers for this process (backlog: requests waiting for a thread; busy_threads), or nil if it is not running under Puma, where there is
  # nothing to read (Puma raises NoMethodError until a server has registered itself).
  def self.puma_stats
    Puma.stats_hash if defined?(Puma) && Puma.respond_to?(:stats_hash)
  rescue NoMethodError
    nil
  end

  DEFAULT_BACKLOG = -> { LoadShedder.puma_stats&.fetch(:backlog, nil) }

  def initialize(app, backlog: DEFAULT_BACKLOG)
    @app = app
    @backlog = backlog
  end

  def call(env)
    return @app.call(env) unless shed?(env)

    Rails.event.notify("load_shed.rejected", path_class: "expensive")
    [ 503, { "content-type" => "application/json; charset=utf-8", "retry-after" => retry_after.to_s, "cache-control" => "no-store", "x-load-shed" => "true" }, [ body(env) ] ]
  end

  private
    def shed?(env)
      return false unless Rails.configuration.x.load_shedding
      return false unless expensive?(env)

      (queued = @backlog.call) && queued >= Rails.configuration.x.load_shedding_backlog
    rescue StandardError
      false # the signal failing must never fail a request
    end

    # GET and HEAD of the expensive paths, and GraphQL / AI (POSTs that only read or only cost model budget).
    def expensive?(env)
      path = env["PATH_INFO"]
      return false unless EXPENSIVE.match?(path)

      env["REQUEST_METHOD"].in?(%w[GET HEAD]) || path.start_with?("/api/v1/graphql", "/api/v1/ai/")
    end

    # A second or two, spread, so the clients that were all refused together do not all come back together.
    def retry_after = 1 + rand(2)

    def body(env)
      ErrorSerializer.new(
        status: :service_unavailable, code: "overloaded", request_id: env["action_dispatch.request_id"],
        message: "The service is busy and is serving cheaper requests first. Retry in a moment."
      ).to_json
    end
end

Rails.application.config.middleware.insert_after ActionDispatch::RequestId, LoadShedder
