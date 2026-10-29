# Request context for structured events: every Rails.event emitted while a request is handled carries
# its request id (and the user id once known; see ApplicationController#annotate_request). Defined here,
# not under app/, because middleware must exist before application code can be autoloaded.
class RequestEventContext
  def initialize(app) = @app = app

  def call(env)
    Rails.event.set_context(request_id: env["action_dispatch.request_id"])
    @app.call(env)
  ensure
    Rails.event.clear_context
  end
end

Rails.application.config.middleware.insert_after ActionDispatch::RequestId, RequestEventContext
