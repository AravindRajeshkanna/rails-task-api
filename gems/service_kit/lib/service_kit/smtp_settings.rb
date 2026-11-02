require "active_support/core_ext/object/blank"

module ServiceKit
  # ActionMailer's smtp_settings, from the environment:
  #
  #   SMTP_ADDRESS    the relay (required)
  #   SMTP_PORT       587
  #   SMTP_USERNAME   with SMTP_PASSWORD: sign in (PLAIN, over STARTTLS) when given
  #
  # Signing in is asked for only when there is a user name. A relay that wants none (Mailpit, the mail catcher in docker compose
  # and kind) has nothing to answer a login with, and Net::SMTP refuses to start the session at all ("SMTP-AUTH requested but
  # missing user name"); one that wants a login (SES) is given it.
  module SmtpSettings
    def self.from_env(env = ENV)
      settings = { address: env.fetch("SMTP_ADDRESS"), port: Integer(env.fetch("SMTP_PORT", 587)), open_timeout: 5, read_timeout: 10 }
      return settings if env["SMTP_USERNAME"].blank?

      settings.merge(user_name: env["SMTP_USERNAME"], password: env["SMTP_PASSWORD"], authentication: :plain, enable_starttls_auto: true)
    end
  end
end
