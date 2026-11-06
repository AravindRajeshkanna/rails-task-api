require "active_support/core_ext/object/blank"

module ServiceKit
  # ActionMailer's smtp_settings, from the environment:
  #
  #   SMTP_ADDRESS    the relay (required)
  #   SMTP_PORT       587
  #   SMTP_USERNAME   with SMTP_PASSWORD: sign in (PLAIN, over STARTTLS) when given
  #
  # A service that keeps the login in its Rails credentials passes it as a second argument, `{ user_name:, password: }`, which wins over the environment.
  #
  # Signing in is asked for only when there is a user name. A relay that wants none (Mailpit, the mail catcher in docker compose
  # and kind) has nothing to answer a login with, and Net::SMTP refuses to start the session at all ("SMTP-AUTH requested but
  # missing user name"); one that wants a login (SES) is given it.
  module SmtpSettings
    def self.from_env(env = ENV, credentials = {})
      settings = { address: env.fetch("SMTP_ADDRESS"), port: Integer(env.fetch("SMTP_PORT", 587)), open_timeout: 5, read_timeout: 10 }
      user_name = credentials[:user_name].presence || env["SMTP_USERNAME"]
      return settings if user_name.blank?

      settings.merge(user_name: user_name, password: credentials[:password].presence || env["SMTP_PASSWORD"], authentication: :plain, enable_starttls_auto: true)
    end
  end
end
