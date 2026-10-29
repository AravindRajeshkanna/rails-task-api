module Api
  module V1
    class RegistrationsController < ApplicationController
      rate_limit to: 10, within: 1.hour, only: :create, with: -> { rate_limited }

      def create
        user = User.create!(params.permit(:name, :email_address, :password))
        render json: { data: AuthService::TokenIssuer.session_for(user, request) }, status: :created
      end
    end
  end
end
