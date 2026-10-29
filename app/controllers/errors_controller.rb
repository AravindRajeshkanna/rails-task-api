# Renders the JSON error envelope for errors raised outside controllers
# (routing errors, unparseable JSON bodies, unexpected exceptions).
# Wired up through `config.exceptions_app = routes`.
class ErrorsController < ActionController::API
  def show
    # path_parameters, not params: `params` would re-parse the (possibly malformed) request body.
    status = request.path_parameters[:status].to_i
    status = 500 unless Rack::Utils::HTTP_STATUS_CODES.key?(status) && status >= 400

    message = "The request could not be parsed" if status == 400

    render json: ErrorSerializer.for_status(status, message: message, request_id: request.request_id), status: status
  end
end
