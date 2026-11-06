require "spec_helper"
require "service_kit/smtp_settings"

RSpec.describe ServiceKit::SmtpSettings do
  let(:relay) { { "SMTP_ADDRESS" => "email-smtp.us-east-1.amazonaws.com" } }

  it "signs in with PLAIN over STARTTLS when there is a user name (SES)" do
    settings = described_class.from_env(relay.merge("SMTP_USERNAME" => "AKIA", "SMTP_PASSWORD" => "secret"))

    expect(settings).to eq(
      address: "email-smtp.us-east-1.amazonaws.com", port: 587, user_name: "AKIA", password: "secret",
      authentication: :plain, enable_starttls_auto: true, open_timeout: 5, read_timeout: 10
    )
  end

  it "does not ask to sign in when there is no user name (the mail catcher in docker compose and kind)" do
    settings = described_class.from_env(relay.merge("SMTP_ADDRESS" => "mailpit", "SMTP_PORT" => "1025"))

    expect(settings).to eq(address: "mailpit", port: 1025, open_timeout: 5, read_timeout: 10)
  end

  it "treats an empty user name as none, as an unset secret reads" do
    expect(described_class.from_env(relay.merge("SMTP_USERNAME" => "", "SMTP_PASSWORD" => ""))).not_to include(:authentication, :user_name)
  end

  it "takes the environment as a bare hash, as callers write it: a second argument must not turn that into keywords" do
    expect(described_class.from_env("SMTP_ADDRESS" => "mailpit", "SMTP_PORT" => "1025")).to eq(address: "mailpit", port: 1025, open_timeout: 5, read_timeout: 10)
  end

  it "signs in with a login kept in the Rails credentials, which wins over the environment (the Task API's, before it shared this)" do
    settings = described_class.from_env(relay.merge("SMTP_USERNAME" => "from-env", "SMTP_PASSWORD" => "env-secret"), { user_name: "from-credentials", password: "credentials-secret" })

    expect(settings).to include(user_name: "from-credentials", password: "credentials-secret", authentication: :plain, enable_starttls_auto: true)
  end

  it "falls back to the environment for whatever the credentials leave out, and asks for no login when neither has a user name" do
    expect(described_class.from_env(relay.merge("SMTP_USERNAME" => "AKIA", "SMTP_PASSWORD" => "secret"), { user_name: nil, password: nil }))
      .to include(user_name: "AKIA", password: "secret")
    expect(described_class.from_env(relay, { user_name: nil, password: "orphan" })).not_to include(:authentication, :user_name, :password)
  end

  it "needs a relay: a missing address stops the boot rather than mailing nowhere" do
    expect { described_class.from_env({}) }.to raise_error(KeyError, /SMTP_ADDRESS/)
  end

  it "refuses a port that is not a number" do
    expect { described_class.from_env(relay.merge("SMTP_PORT" => "smtp")) }.to raise_error(ArgumentError)
  end
end
