# Bearer-token authentication, adapted from the Rails 8 authentication generator
# (which uses cookie sessions). Clients send `Authorization: Bearer <token>`.
module Authentication
  extend ActiveSupport::Concern

  class NotAuthenticated < StandardError; end

  included do
    before_action :require_authentication
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private
    def require_authentication
      resume_session || request_authentication
    end

    def resume_session
      Current.session ||= find_session_by_token
    end

    def find_session_by_token
      token, _options = ActionController::HttpAuthentication::Token.token_and_options(request)
      Session.authenticate(token)
    end

    def request_authentication
      response.headers["WWW-Authenticate"] = 'Bearer realm="task_api"'
      raise NotAuthenticated
    end

    def current_user = Current.user

    # Returns the plaintext token; it cannot be recovered later.
    def start_new_session_for(user)
      session, token = Session.start_for!(user, ip_address: request.remote_ip, user_agent: request.user_agent)
      Current.session = session
      token
    end

    def terminate_session
      Current.session.destroy
      Current.reset
    end
end
