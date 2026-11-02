require "rails_helper"
require "timeout"

# The production settings meet a relay that offers no login, as Mailpit does in docker compose and kind. With
# `authentication: :plain` and no user name, Net::SMTP refuses to start the session ("SMTP-AUTH requested but missing user
# name"), which ended the consumer on the first email it tried to send.
RSpec.describe "Sending through a relay without a login" do
  let(:relay) { NoLoginRelay.new }

  after { relay.stop }

  it "delivers with the settings production builds from an environment that has no SMTP_USERNAME" do
    settings = ServiceKit::SmtpSettings.from_env("SMTP_ADDRESS" => "127.0.0.1", "SMTP_PORT" => relay.port.to_s)
    mail = Mail.new(from: "no-reply@example.com", to: "bob@example.com", subject: "You were assigned: Check the platform", body: "Hello Bob")
    mail.delivery_method :smtp, settings

    Timeout.timeout(5) { mail.deliver! }

    expect(Timeout.timeout(5) { relay.received.pop }).to include("Subject: You were assigned: Check the platform", "Hello Bob")
  end

  it "is the settings the production environment uses" do
    expect(File.read(Rails.root.join("config/environments/production.rb"))).to include("ServiceKit::SmtpSettings.from_env")
  end
end
