# One error envelope for every failure, the same as the monolith's:
#   { "error": { "status": 422, "code": "validation_failed", "message": "...", "details": { ... } } }
class ApplicationController < ActionController::API
  wrap_parameters false

  rescue_from ActionController::ParameterMissing do |error|
    render_error :bad_request, "parameter_missing", error.message
  end
  rescue_from ActiveRecord::RecordInvalid do |error|
    render_error :unprocessable_content, "validation_failed", "Validation failed", error.record.errors.messages
  end
  rescue_from ActiveRecord::RecordNotUnique do
    render_error :conflict, "conflict", "A record with these values already exists"
  end

  private
    def render_error(status, code, message, details = nil)
      error = { status: Rack::Utils.status_code(status), code: code, message: message }
      error[:details] = details if details.present?
      render json: { error: error }, status: status
    end

    def rate_limited = render_error(:too_many_requests, "rate_limited", "Too many attempts. Try again later.")
end
