module Api
  module V1
    # Whether a password is a person's, for the Task API's DELETE /me (ADR 79): it holds no password for a person this service owns, and erasing an account
    # asks for the password again so that a stolen token alone cannot do it. 204 or 401; nothing is issued, so it is no way into anything.
    #
    # Not routed by the ingress (the chart lists the public paths): only the pods the network policy lets in can ask, the Task API's on behalf of a signed-in
    # person who is limited to five attempts an hour over there. The limit on an address here is the second lock, as the one on signing in is.
    class CredentialChecksController < ApplicationController
      rate_limit to: 5, within: 1.minute, by: -> { params[:email_address].to_s.strip.downcase }, with: -> { rate_limited }

      def create
        if User.authenticate_by(params.permit(:email_address, :password).to_h.symbolize_keys)
          head :no_content
        else
          render_error :unauthorized, "invalid_credentials", "Invalid email address or password"
        end
      end
    end
  end
end
