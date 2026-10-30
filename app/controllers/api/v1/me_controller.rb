module Api
  module V1
    class MeController < BaseController
      # Acting on yourself needs no policy.
      skip_after_action :verify_authorized
      rate_limit to: 5, within: 1.hour, only: :destroy, by: -> { Current.user.id }, with: -> { render_error :too_many_requests, "rate_limited", "Too many attempts. Try again later." }

      def show
        render_resource UserResource, current_user
      end

      def update
        # With AUTH_MODE=jwt the Auth service owns the profile; a local edit would be overwritten on the next login.
        return render_error(:conflict, "managed_by_auth_service", "Your name and email are managed by the Auth service") if ExternalAuth.enabled?

        current_user.update!(params.permit(:name))
        render_resource UserResource, current_user
      end

      # DELETE /me: erase the account (AccountErasure). Needs the password again, so a stolen token alone cannot do it.
      def destroy
        return render_error(:conflict, "managed_by_auth_service", "Your account is managed by the Auth service") if ExternalAuth.enabled?
        return render_error(:unprocessable_content, "incorrect_password", "The password is incorrect") unless current_user.authenticate(params[:password].to_s)

        AccountErasure.call(current_user)
        head :no_content
      rescue AccountErasure::Blocked => error
        render_error :unprocessable_content, error.code, error.message
      end
    end
  end
end
