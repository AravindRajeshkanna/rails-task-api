require "rails_helper"

RSpec.describe "Rate limiting" do
  around do |example|
    original_store = Rack::Attack.cache.store
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.enabled = true
    example.run
  ensure
    Rack::Attack.enabled = false
    Rack::Attack.cache.store = original_store
  end

  describe "Rack::Attack" do
    it "throttles login attempts per email, whatever the client sends" do
      5.times do
        post "/api/v1/session", params: { email_address: "Victim@example.com", password: "guess" }.to_json,
                                headers: { "Content-Type" => "application/json" }
        expect(response).to have_http_status(:unauthorized)
      end

      post "/api/v1/session", params: { email_address: " victim@EXAMPLE.com ", password: "guess" }.to_json,
                              headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers["Retry-After"].to_i).to be_between(1, 60)
      expect(error).to include("status" => 429, "code" => "rate_limited")
    end

    it "does not throttle other accounts" do
      5.times { post "/api/v1/session", params: { email_address: "a@example.com", password: "x" }.to_json, headers: { "Content-Type" => "application/json" } }

      post "/api/v1/session", params: { email_address: "b@example.com", password: "x" }.to_json, headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "throttles a single bearer token" do
      stub_const("Rack::Attack::Check", Rack::Attack::Check) # keep constant lookup stable
      throttle = Rack::Attack.throttles.fetch("api/token")
      allow(throttle).to receive(:limit).and_return(3)
      headers = auth_headers(create(:user))

      3.times { get "/api/v1/me", headers: headers }
      expect(response).to have_http_status(:ok)

      get "/api/v1/me", headers: headers
      expect(response).to have_http_status(:too_many_requests)
    end

    it "does not throttle anything outside /api" do
      10.times { get "/up" }

      expect(response).to have_http_status(:ok)
    end
  end

  describe "controller rate_limit" do
    it "answers sign-up floods with the standard envelope" do
      allow(Rails.cache).to receive(:increment).and_return(11)

      post "/api/v1/registrations", params: { name: "A", email_address: "a@example.com", password: "long-enough-pw" }.to_json,
                                    headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:too_many_requests)
      expect(error["code"]).to eq("rate_limited")
      expect(User.count).to eq(0)
    end
  end
end
