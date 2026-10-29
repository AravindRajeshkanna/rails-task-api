module Api
  module V1
    class PasswordsController < ApplicationController
      rate_limit to: 10, within: 3.minutes, only: :create, with: -> { rate_limited }

      # Always 202, whether or not the address exists, so this cannot be used to find out who has an account.
      def create
        if (user = User.find_by(email_address: params[:email_address].to_s.strip.downcase))
          AuthService::Events.publish("user.password_reset_requested", {
            recipient: { id: user.uid, name: user.name, email_address: user.email_address },
            reset_url: "#{Rails.configuration.x.frontend_url}/reset-password?token=#{CGI.escape(user.password_reset_token)}",
            expires_in_minutes: user.password_reset_token_expires_in / 60
          })
        end
        head :accepted
      end

      def update
        user = User.find_by_password_reset_token!(params[:token])

        if user.update(params.permit(:password, :password_confirmation))
          user.refresh_tokens.update_all(revoked_at: Time.current) # rubocop:disable Rails/SkipsModelValidations -- a reset signs out every device
          head :no_content
        else
          render_error :unprocessable_content, "validation_failed", "Validation failed", user.errors.messages
        end
      rescue ActiveSupport::MessageVerifier::InvalidSignature
        render_error :unprocessable_content, "invalid_token", "Password reset link is invalid or has expired"
      end
    end
  end
end
