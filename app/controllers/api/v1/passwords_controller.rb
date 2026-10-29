module Api
  module V1
    class PasswordsController < BaseController
      allow_unauthenticated_access
      skip_after_action :verify_authorized
      rate_limit to: 10, within: 3.minutes, only: :create, with: -> { render_error :too_many_requests, "rate_limited", "Too many requests. Try again later." }

      # Always answers 202, whether or not the address exists, so the endpoint
      # cannot be used to discover which emails are registered.
      def create
        if (user = User.find_by(email_address: params[:email_address].to_s.strip.downcase))
          PasswordsMailer.reset(user).deliver_later
        end

        head :accepted
      end

      def update
        user = User.find_by_password_reset_token!(params[:token])

        if user.update(params.permit(:password, :password_confirmation))
          user.sessions.destroy_all # a reset signs out every device
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
