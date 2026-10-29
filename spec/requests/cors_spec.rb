require "rails_helper"

RSpec.describe "CORS" do
  it "answers preflight requests from allowed origins" do
    options "/api/v1/projects", headers: {
      "Origin" => "http://localhost:5173",
      "Access-Control-Request-Method" => "POST",
      "Access-Control-Request-Headers" => "authorization,content-type"
    }

    expect(response).to have_http_status(:ok)
    expect(response.headers["Access-Control-Allow-Origin"]).to eq("http://localhost:5173")
    expect(response.headers["Access-Control-Allow-Methods"]).to include("POST")
  end

  it "exposes pagination headers to browsers" do
    user = create(:user)

    get "/api/v1/projects", headers: auth_headers(user).merge("Origin" => "http://localhost:5173")

    expect(response.headers["Access-Control-Expose-Headers"]).to include("Total-Count", "Link")
  end

  it "does not grant access to other origins" do
    options "/api/v1/projects", headers: {
      "Origin" => "https://evil.example",
      "Access-Control-Request-Method" => "GET"
    }

    expect(response.headers["Access-Control-Allow-Origin"]).to be_nil
  end
end
