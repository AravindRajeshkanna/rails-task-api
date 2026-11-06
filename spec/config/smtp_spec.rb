require "rails_helper"
require "timeout"
require "service_kit/smtp_settings" # what production.rb requires when SMTP_ADDRESS is set

# The Task API sends mail itself in NOTIFICATIONS_MODE=local (and for the invitations and digests that are not events yet). Its production settings used to ask
# for a login whatever the relay offered, as the Notification service's did until docker compose and kind met a relay with none (Mailpit): with
# `authentication: :plain` and no user name, Net::SMTP refuses to start the session ("SMTP-AUTH requested but missing user name"). Neither platform stack
# sends mail through the Task API, so nothing had run these settings against a relay without a login.
RSpec.describe "Sending through a relay without a login" do
  let(:relay) { NoLoginRelay.new }
  let(:production) { Rails.root.join("config/environments/production.rb").each_line.reject { |line| line.strip.start_with?("#") }.join } # the code, not Rails' commented template

  after { relay.stop }

  it "delivers with the settings production builds from an environment that has no SMTP_USERNAME" do
    settings = ServiceKit::SmtpSettings.from_env({ "SMTP_ADDRESS" => "127.0.0.1", "SMTP_PORT" => relay.port.to_s }, {})
    mail = Mail.new(from: "no-reply@example.com", to: "bob@example.com", subject: "You were invited to Acme", body: "Hello Bob")
    mail.delivery_method :smtp, settings

    Timeout.timeout(5) { mail.deliver! }

    expect(Timeout.timeout(5) { relay.received.pop }).to include("Subject: You were invited to Acme", "Hello Bob")
  end

  it "is the settings the production environment uses, with the login it keeps in its credentials passed through" do
    expect(production).to include("ServiceKit::SmtpSettings.from_env(")
    expect(production).to include("user_name: Rails.application.credentials.dig(:smtp, :user_name)", "password: Rails.application.credentials.dig(:smtp, :password)")
    expect(production).not_to include("authentication: :plain") # asked for only by the helper, and only with a user name
  end
end
