class PasswordsMailer < ApplicationMailer
  def reset(user)
    @user = user
    @reset_url = frontend_url("/reset-password?token=#{CGI.escape(user.password_reset_token)}")
    @expires_in = ActiveSupport::Duration.build(user.password_reset_token_expires_in).inspect
    mail subject: "Reset your password", to: user.email_address
  end
end
