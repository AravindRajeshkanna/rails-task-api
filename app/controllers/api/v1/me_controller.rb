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

      # DELETE /me: erase the account (AccountErasure). Needs the password again, so a stolen token alone cannot do it. Where the Auth service owns the
      # accounts it is asked whether the password is right, and it is told to delete the identity afterwards through the outbox (ADR 79).
      def destroy
        return render_error(:unprocessable_content, "incorrect_password", "The password is incorrect") unless password_correct?

        AccountErasure.call(current_user)
        head :no_content
      rescue AccountErasure::Blocked => error
        render_error :unprocessable_content, error.code, error.message
      end

      private
        def password_correct?
          password = params[:password].to_s
          ExternalAuth.enabled? ? ExternalAuth.password_correct?(current_user, password) : current_user.authenticate(password)
        end
    end
  end
end
