require "rails_helper"

RSpec.describe "Security headers" do
  let(:user) { create(:user) }

  def expect_locked_down
    expect(response.headers).to include(
      "X-Frame-Options" => "DENY",
      "X-Content-Type-Options" => "nosniff",
      "Referrer-Policy" => "no-referrer",
      "X-Permitted-Cross-Domain-Policies" => "none"
    )
    directives = response.headers["Content-Security-Policy"].split("; ")
    expect(directives).to contain_exactly(
      "default-src 'none'", "object-src 'none'", "script-src 'none'",
      "base-uri 'none'", "form-action 'none'", "frame-ancestors 'none'"
    )
  end

  it "locks down API responses and never sets a cookie" do
    api :get, "/api/v1/me", as: user

    expect(response).to have_http_status(:ok)
    expect_locked_down
    expect(response.headers).not_to include("Set-Cookie")
  end

  it "locks down error responses too" do
    get "/api/v1/me"

    expect(response).to have_http_status(:unauthorized)
    expect_locked_down
  end

  it "locks down answers produced before Rails routes the request (Rack::Attack)" do
    original_store = Rack::Attack.cache.store
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.enabled = true
    6.times { api :post, "/api/v1/session", { email_address: "someone@example.com", password: "nope" } }

    expect(response).to have_http_status(:too_many_requests)
    expect_locked_down
  ensure
    Rack::Attack.enabled = false
    Rack::Attack.cache.store = original_store
  end

  it "lets Swagger UI load its own scripts and styles, and nothing else" do
    get "/api-docs/index.html"

    expect(response).to have_http_status(:ok)
    policy = response.headers["Content-Security-Policy"]
    expect(policy).to include("script-src 'self' 'unsafe-inline'", "frame-ancestors 'none'")
    expect(policy).not_to include("default-src 'none'")
  end
end
