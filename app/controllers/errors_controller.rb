# Renders the JSON error envelope for errors raised outside controllers
# (routing errors, unparseable JSON bodies, unexpected exceptions).
# Wired up through `config.exceptions_app = routes`.
class ErrorsController < ActionController::API
  def show
    # path_parameters, not params: `params` would re-parse the (possibly malformed) request body.
    status = request.path_parameters[:status].to_i
    status = 500 unless Rack::Utils::HTTP_STATUS_CODES.key?(status) && status >= 400

    # Rack's status table holds binary (ASCII-8BIT) strings, which String#parameterize rejects.
    reason = Rack::Utils::HTTP_STATUS_CODES[status].dup.force_encoding(Encoding::UTF_8)
    message = status == 400 ? "The request could not be parsed" : reason

    render json: {
      error: { status: status, code: reason.parameterize(separator: "_"), message: message }
    }, status: status
  end
end
