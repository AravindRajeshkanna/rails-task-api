module Api
  module V1
    class AvatarsController < BaseController
      skip_after_action :verify_authorized

      # PUT /api/v1/me/avatar  (multipart/form-data, field "avatar")
      def update
        avatar = params[:avatar]
        raise ActionController::ParameterMissing.new(:avatar) unless avatar.is_a?(ActionDispatch::Http::UploadedFile)

        # On a persisted record `attach` validates and saves; nothing is uploaded when it fails.
        current_user.avatar.attach(avatar)
        raise ActiveRecord::RecordInvalid.new(current_user) if current_user.errors.any?

        render_resource UserResource, current_user
      end

      def destroy
        current_user.avatar.purge_later
        head :no_content
      end
    end
  end
end
