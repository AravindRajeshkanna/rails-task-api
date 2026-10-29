# The one place that knows the shape of an error response:
#
#   { "error": { "status": 422, "code": "validation_failed", "message": "Validation failed",
#                "details": { "title": ["can't be blank"] }, "request_id": "9f1c..." } }
#
# `details` appears only when there is something to say; `request_id` echoes the
# X-Request-Id response header so a client can quote it in a bug report.
#
# Used by ErrorHandling (controller rescues), ErrorsController (errors raised outside
# controllers) and Rack::Attack (throttling), so no failure can drift from the contract.
class ErrorSerializer
  attr_reader :status, :code, :message, :details, :request_id

  # For a bare HTTP status with no domain meaning (404 from the router, 400 from a bad body):
  # the code is the reason phrase, e.g. 404 => "not_found".
  def self.for_status(status, message: nil, request_id: nil)
    # Rack's status table holds binary (ASCII-8BIT) strings, which String#parameterize rejects.
    reason = Rack::Utils::HTTP_STATUS_CODES.fetch(status).dup.force_encoding(Encoding::UTF_8)
    new(status: status, code: reason.parameterize(separator: "_"), message: message || reason, request_id: request_id)
  end

  def initialize(status:, code:, message:, details: nil, request_id: nil)
    @status = Rack::Utils.status_code(status)
    @code = code
    @message = message
    @details = details
    @request_id = request_id
  end

  def as_json(*)
    error = { status: status, code: code, message: message }
    error[:details] = details if details.present?
    error[:request_id] = request_id if request_id.present?
    { error: error }
  end
end
