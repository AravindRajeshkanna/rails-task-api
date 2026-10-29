module Api
  module V1
    class RegistrationsController < BaseController
      allow_unauthenticated_access only: :create
      skip_after_action :verify_authorized
      rate_limit to: 10, within: 1.hour, only: :create, with: -> { render_error :too_many_requests, "rate_limited", "Too many sign-up attempts. Try again later." }

      def create
        user = User.create!(registration_params)
        token = start_new_session_for(user)
        prevent_storage
        render_resource SessionResource, Current.session, status: :created, params: { token: token }
      end

      private
        def registration_params
          params.permit(:name, :email_address, :password)
        end
    end
  end
end
