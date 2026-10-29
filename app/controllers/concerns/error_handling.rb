# One error envelope for every failure:
#
#   { "error": { "status": 422, "code": "validation_failed", "message": "...", "details": { ... } } }
#
# Errors raised outside controllers (bad JSON, unknown routes) get the same shape
# from ErrorsController via config.exceptions_app.
module ErrorHandling
  extend ActiveSupport::Concern

  included do
    rescue_from ActiveRecord::RecordNotUnique do
      render_error :conflict, "conflict", "A record with these values already exists"
    end
    rescue_from ActiveRecord::StaleObjectError do
      render_error :conflict, "stale_object", "The record was changed by someone else; reload it and try again"
    end
    rescue_from ActionController::ParameterMissing do |error|
      render_error :bad_request, "parameter_missing", error.message
    end
    rescue_from InvalidParameterError do |error|
      render_error :bad_request, "invalid_parameter", error.message, parameter: error.parameter
    end
    rescue_from ActiveRecord::RecordInvalid do |error|
      render_error :unprocessable_content, "validation_failed", "Validation failed", error.record.errors.messages
    end
    rescue_from ActiveRecord::RecordNotFound do
      render_error :not_found, "not_found", "Resource not found"
    end
    rescue_from Pundit::NotAuthorizedError do
      render_error :forbidden, "forbidden", "You are not allowed to perform this action"
    end
    # AI failures: declared before the specific ones, because the last matching rescue_from wins.
    rescue_from Ai::Error do |error|
      render_error :bad_gateway, "ai_error", error.message
    end
    rescue_from Ai::InvalidResponse do
      render_error :bad_gateway, "ai_invalid_response", "The AI model returned an unusable answer. Try again."
    end
    rescue_from Ai::Unavailable do
      response.headers["Retry-After"] = "5"
      render_error :service_unavailable, "ai_unavailable", "The AI provider is busy or unreachable. Try again shortly."
    end
    rescue_from Ai::Disabled do
      render_error :service_unavailable, "ai_not_configured", "AI features are not configured on this server"
    end
    rescue_from Ai::BudgetExceeded do |error|
      response.headers["Retry-After"] = error.retry_after.to_s
      render_error :too_many_requests, "ai_budget_exceeded", "The daily AI budget has been used up. It resets at 00:00 UTC."
    end
    rescue_from ExternalAuth::AccountConflict do
      render_error :conflict, "account_conflict", "Another account already uses this email address. Contact support to link them."
    end
    rescue_from ExternalAuth::Unavailable do
      response.headers["Retry-After"] = "5"
      render_error :service_unavailable, "auth_unavailable", "The authentication service is unreachable. Try again shortly."
    end
    rescue_from Authentication::NotAuthenticated do
      render_error :unauthorized, "unauthenticated", "Authentication is required"
    end
  end

  private
    def render_error(status, code, message, details = nil)
      error = { status: Rack::Utils.status_code(status), code: code, message: message }
      error[:details] = details if details.present?
      render json: { error: error }, status: status
    end
end
