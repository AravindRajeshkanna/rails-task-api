module Api
  module V1
    class SessionsController < ApplicationController
      rate_limit to: 10, within: 3.minutes, only: :create, name: "login-ip", with: -> { rate_limited }
      rate_limit to: 5, within: 1.minute, only: :create, name: "login-email", by: -> { params[:email_address].to_s.strip.downcase }, with: -> { rate_limited }
      rate_limit to: 30, within: 1.minute, only: :refresh, with: -> { rate_limited }

      def create
        if (user = User.authenticate_by(params.permit(:email_address, :password).to_h.symbolize_keys))
          render json: { data: AuthService::TokenIssuer.session_for(user, request) }, status: :created
        else
          render_error :unauthorized, "invalid_credentials", "Invalid email address or password"
        end
      end

      # Trade a refresh token for a new access token and a new refresh token. The old one stops working.
      def refresh
        record, token = RefreshToken.rotate!(params.require(:refresh_token), ip_address: request.remote_ip, user_agent: request.user_agent)
        jwt, expires_at = AuthService::TokenIssuer.access_token(record.user)
        render json: { data: AuthService::TokenIssuer.payload(record.user, jwt, expires_at, token, record.expires_at) }
      rescue RefreshToken::Reused
        render_error :unauthorized, "refresh_token_reused", "This refresh token was already used; all sessions from this sign-in were ended. Sign in again."
      rescue RefreshToken::Invalid
        render_error :unauthorized, "invalid_refresh_token", "The refresh token is invalid or has expired"
      end

      # Ends the sign-in the refresh token belongs to. Access tokens already issued live until they expire
      # (at most the access TTL, 15 minutes by default); that is the price of verifying them without a lookup.
      def destroy
        RefreshToken.revoke!(params[:refresh_token])
        head :no_content
      end
    end
  end
end
