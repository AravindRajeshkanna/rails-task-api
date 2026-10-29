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
