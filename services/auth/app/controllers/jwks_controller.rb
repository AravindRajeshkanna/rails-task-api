class JwksController < ApplicationController
  def show
    expires_in 5.minutes, public: true
    render json: AuthService::Keys.jwks
  end
end
