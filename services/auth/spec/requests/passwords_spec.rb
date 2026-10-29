require "rails_helper"

RSpec.describe "Password reset", type: :request do
  let!(:user) { create(:user, email_address: "pat@example.com", name: "Pat Person") }
  let(:sns) { Aws::SNS::Client.new(stub_responses: true, region: "us-east-1") }

  around do |example|
    Rails.configuration.x.events.sns_topic_arn = "arn:aws:sns:us-east-1:123456789012:task-api-events"
    AuthService::Events.client = sns
    example.run
  ensure
    Rails.configuration.x.events.sns_topic_arn = nil
    AuthService::Events.client = nil
  end

  it "publishes an event with the link, for the Notification service to email" do
    post_json("/api/v1/passwords", { email_address: "Pat@Example.com" })

    expect(response).to have_http_status(:accepted)
    request = sns.api_requests.sole[:params]
    envelope = JSON.parse(request[:message])
    expect(envelope).to include("specversion" => "1.0", "type" => "user.password_reset_requested", "source" => "auth-service")
    expect(envelope["data"]["recipient"]).to include("name" => "Pat Person", "email_address" => "pat@example.com")
    expect(envelope["data"]["reset_url"]).to start_with("#{Rails.configuration.x.frontend_url}/reset-password?token=")
    expect(request[:message_attributes]["type"][:string_value]).to eq("user.password_reset_requested")
  end

  it "answers the same for unknown addresses and publishes nothing" do
    post_json("/api/v1/passwords", { email_address: "nobody@example.com" })

    expect(response).to have_http_status(:accepted)
    expect(sns.api_requests).to be_empty
  end

  it "still answers 202 when the event cannot be published" do
    sns.stub_responses(:publish, "InternalErrorException")

    post_json("/api/v1/passwords", { email_address: "pat@example.com" })

    expect(response).to have_http_status(:accepted)
  end

  it "only logs the event when no topic is configured (local development)" do
    Rails.configuration.x.events.sns_topic_arn = nil

    post_json("/api/v1/passwords", { email_address: "pat@example.com" })

    expect(response).to have_http_status(:accepted)
    expect(sns.api_requests).to be_empty
  end

  describe "PATCH /api/v1/passwords/:token" do
    it "sets the new password and signs out every device" do
      refresh = sign_in(user)["refresh_token"]

      patch_json("/api/v1/passwords/#{CGI.escape(user.password_reset_token)}", { password: "a-brand-new-password", password_confirmation: "a-brand-new-password" })

      expect(response).to have_http_status(:no_content)
      expect(User.authenticate_by(email_address: "pat@example.com", password: "a-brand-new-password")).to eq(user)
      post_json("/api/v1/session/refresh", { refresh_token: refresh })
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects a bad or expired link" do
      patch_json("/api/v1/passwords/garbage", { password: "a-brand-new-password" })
      expect(response).to have_http_status(:unprocessable_content)
      expect(error["code"]).to eq("invalid_token")

      token = user.password_reset_token
      travel_to(16.minutes.from_now) { patch_json("/api/v1/passwords/#{CGI.escape(token)}", { password: "a-brand-new-password" }) }
      expect(error["code"]).to eq("invalid_token")
    end

    it "rejects a weak password and keeps the old one" do
      patch_json("/api/v1/passwords/#{CGI.escape(user.password_reset_token)}", { password: "short" })

      expect(response).to have_http_status(:unprocessable_content)
      expect(User.authenticate_by(email_address: "pat@example.com", password: "correct-horse-battery")).to eq(user)
    end
  end
end
