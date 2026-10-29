# Every endpoint takes a shared bearer token, enforces a body size cap, and answers errors in one
# envelope: { "error": { "code": "...", "message": "..." } }.
class ApplicationController < ActionController::API
  MAX_BODY_BYTES = 512.kilobytes

  wrap_parameters false
  before_action :authenticate_service!
  before_action :limit_body_size
  rate_limit to: Rails.configuration.x.rate_limit_per_minute, within: 1.minute,
    with: -> { render_error :too_many_requests, "rate_limited", "Too many requests" }

  rescue_from ActionController::ParameterMissing do |error|
    render_error :bad_request, "invalid_request", error.message
  end
  rescue_from AiCore::Error do |error|
    render_error :bad_gateway, "ai_error", error.message
  end
  rescue_from AiCore::InvalidResponse do |error|
    render_error :bad_gateway, "ai_invalid_response", error.message
  end
  rescue_from AiCore::Unavailable do
    response.headers["Retry-After"] = "5"
    render_error :service_unavailable, "ai_unavailable", "The model provider is busy or unreachable"
  end
  rescue_from AiCore::ConfigurationError do
    render_error :service_unavailable, "ai_not_configured", "No model provider is configured"
  end

  private
    def authenticate_service!
      expected = ENV["AI_SERVICE_TOKEN"].to_s
      return if expected.empty? && !Rails.env.production? # local development without a token

      provided = request.authorization.to_s.delete_prefix("Bearer ")
      return if expected.present? && ActiveSupport::SecurityUtils.secure_compare(provided, expected)

      response.headers["WWW-Authenticate"] = 'Bearer realm="ai-service"'
      render_error :unauthorized, "unauthorized", "A valid service token is required"
    end

    def limit_body_size
      render_error :content_too_large, "invalid_request", "Request body is too large" if request.content_length.to_i > MAX_BODY_BYTES
    end

    def render_error(status, code, message)
      render json: { error: { code: code, message: message } }, status: status
    end

    # A JSON object from the body, as plain Ruby hashes with string keys.
    def json_object(key)
      value = params.require(key)
      raise ActionController::ParameterMissing, key unless value.respond_to?(:to_unsafe_h)

      JSON.parse(value.to_unsafe_h.to_json)
    end
end
