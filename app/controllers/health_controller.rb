# Two questions, answered separately (ADR 63), because getting them mixed up is how a database blip turns into a restart storm:
#
#   GET /livez    Is this process alive? Never looks at anything outside the process. If it fails, the right response is to restart the pod,
#                 so it must fail only when a restart would help: a database that is down is not fixed by restarting every API pod.
#   GET /readyz   Can this instance do useful work right now? Checks what it needs to answer requests (the database). If it fails, the right response
#                 is to stop sending it traffic and leave it running: the pod is fine, its dependency is not.
#
# `/up` (Rails' own) stays as it was, for Kamal and anything that already uses it. No details leave this controller beyond "ok" or "failed" per
# check: it is unauthenticated, so an error message would be reconnaissance.
class HealthController < ActionController::API
  DATABASE_TIMEOUT = 2 # seconds

  def livez
    render_status(:ok, {})
  end

  def readyz
    checks = { database: database_ok? ? "ok" : "failed" }
    render_status(checks.values.all?("ok") ? :ok : :service_unavailable, checks)
  end

  private
    def database_ok?
      Timeout.timeout(DATABASE_TIMEOUT) { ActiveRecord::Base.connection_pool.with_connection { |connection| connection.select_value("SELECT 1") == 1 } }
    rescue StandardError # including Timeout::Error
      false
    end

    def render_status(status, checks)
      response.headers["Cache-Control"] = "no-store"
      render json: { status: status == :ok ? "ok" : "unavailable", checks: checks }, status: status
    end
end
