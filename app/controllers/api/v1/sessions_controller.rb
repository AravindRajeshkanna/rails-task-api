module Api
  module V1
    class SessionsController < BaseController
      allow_unauthenticated_access only: :create
      skip_after_action :verify_authorized
      rate_limit to: 30, within: 1.hour, only: :rotate, by: -> { Current.user.id }, with: -> { render_error :too_many_requests, "rate_limited", "Too many rotations. Try again later." }
      rate_limit to: 10, within: 3.minutes, only: :create, with: -> { render_error :too_many_requests, "rate_limited", "Too many login attempts. Try again later." }

      def create
        if (user = User.authenticate_by(params.permit(:email_address, :password)))
          token = start_new_session_for(user)
          prevent_storage
          render_resource SessionResource, Current.session, status: :created, params: { token: token }
        else
          render_error :unauthorized, "invalid_credentials", "Invalid email address or password"
        end
      end

      # POST /session/rotate: trade the token you are using for a fresh one (same person, same device, new secret). The old one is dead at once, so a
      # token that leaked a week ago is useless after the next rotation. Clients are expected to do this now and then (docs/security.md).
      def rotate
        session, token = Current.session.rotate!(ip_address: request.remote_ip, user_agent: request.user_agent)
        Current.session = session
        Rails.event.notify("session.rotated", session_id: session.id)
        prevent_storage
        render_resource SessionResource, session, status: :created, params: { token: token }
      end

      def destroy
        terminate_session
        head :no_content
      end
    end
  end
end
