module Api
  module V1
    class SessionsController < BaseController
      allow_unauthenticated_access only: :create
      skip_after_action :verify_authorized
      rate_limit to: 10, within: 3.minutes, only: :create, with: -> { render_error :too_many_requests, "rate_limited", "Too many login attempts. Try again later." }

      def create
        if (user = User.authenticate_by(params.permit(:email_address, :password)))
          token = start_new_session_for(user)
          render_resource SessionResource, Current.session, status: :created, params: { token: token }
        else
          render_error :unauthorized, "invalid_credentials", "Invalid email address or password"
        end
      end

      def destroy
        terminate_session
        head :no_content
      end
    end
  end
end
