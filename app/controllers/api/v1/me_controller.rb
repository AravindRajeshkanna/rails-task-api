module Api
  module V1
    class MeController < BaseController
      # Acting on yourself needs no policy.
      skip_after_action :verify_authorized

      def show
        render_resource UserResource, current_user
      end

      def update
        # With AUTH_MODE=jwt the Auth service owns the profile; a local edit would be overwritten on the next login.
        return render_error(:conflict, "managed_by_auth_service", "Your name and email are managed by the Auth service") if ExternalAuth.enabled?

        current_user.update!(params.permit(:name))
        render_resource UserResource, current_user
      end
    end
  end
end
