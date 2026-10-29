class ApplicationMailer < ActionMailer::Base
  default from: -> { Rails.configuration.x.mail_from }
  layout "mailer"

  private
    # Links point at the front-end app, not at this API.
    def frontend_url(path)
      "#{Rails.configuration.x.frontend_url}#{path}"
    end
end
