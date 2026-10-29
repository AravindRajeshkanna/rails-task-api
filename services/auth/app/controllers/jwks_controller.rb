class JwksController < ApplicationController
  skip_before_action :prevent_storage # public keys are meant to be cached (see #show)

  def show
    expires_in 5.minutes, public: true
    render json: AuthService::Keys.jwks
  end
end
