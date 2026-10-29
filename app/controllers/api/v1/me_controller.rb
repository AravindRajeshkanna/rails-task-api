module Api
  module V1
    class MeController < BaseController
      # Acting on yourself needs no policy.
      skip_after_action :verify_authorized

      def show
        render_resource UserResource, current_user
      end

      def update
        current_user.update!(params.permit(:name))
        render_resource UserResource, current_user
      end
    end
  end
end
