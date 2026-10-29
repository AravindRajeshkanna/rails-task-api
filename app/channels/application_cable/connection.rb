module ApplicationCable
  # Authenticates WebSocket clients with the same bearer tokens as the HTTP API.
  # Browsers cannot set headers on a WebSocket, so `?token=` is accepted too
  # (it is in Rails' filter_parameters, so it is scrubbed from logs).
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = find_user || reject_unauthorized_connection
    end

    private
      def find_user
        token, _options = ActionController::HttpAuthentication::Token.token_and_options(request)
        Session.authenticate(token || request.params[:token])&.user
      end
  end
end
