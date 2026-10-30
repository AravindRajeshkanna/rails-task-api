require "rails_helper"

# DELETE /me: ending your own account (ADR 67). What leaves and what stays is covered in spec/services/account_erasure_spec.rb.
RSpec.describe "Account erasure" do
  let(:user) { create(:user, email_address: "ada@example.com") }
  let(:headers) { auth_headers(user).merge("Content-Type" => "application/json") }
  let(:password) { "correct-horse-battery" }

  def erase(password: self.password, as: headers) = delete("/api/v1/me", params: { password: password }.to_json, headers: as)

  it "erases the account and ends the session that asked" do
    erase

    expect(response).to have_http_status(:no_content)
    expect(user.reload).to be_erased
    get "/api/v1/me", headers: headers
    expect(response).to have_http_status(:unauthorized)
    post "/api/v1/session", params: { email_address: "ada@example.com", password: password }.to_json, headers: { "Content-Type" => "application/json" }
    expect(response).to have_http_status(:unauthorized)
  end

  it "needs the password again, so a stolen token alone is not enough" do
    erase(password: "not-my-password")
    expect(response).to have_http_status(:unprocessable_content)
    expect(error["code"]).to eq("incorrect_password")

    delete "/api/v1/me", headers: headers
    expect(error["code"]).to eq("incorrect_password")
    expect(user.reload).not_to be_erased
  end

  it "needs a signed-in caller" do
    delete "/api/v1/me", params: { password: password }.to_json, headers: { "Content-Type" => "application/json" }

    expect(response).to have_http_status(:unauthorized)
  end

  it "says what stands in the way, and changes nothing" do
    create(:project, owner: user, name: "Moon shot")

    erase

    expect(response).to have_http_status(:unprocessable_content)
    expect(error["code"]).to eq("owns_projects")
    expect(error["message"]).to match(/Archive them first/)
    expect(user.reload).not_to be_erased
    get "/api/v1/me", headers: headers
    expect(response).to have_http_status(:ok)
  end

  it "is the Auth service's to do when it owns the accounts" do
    with_jwt_auth do
      erase(as: jwt_headers.merge("Content-Type" => "application/json"))

      expect(response).to have_http_status(:conflict)
      expect(error["code"]).to eq("managed_by_auth_service")
    end
    expect(User.where.not(erased_at: nil)).to be_empty
  end

  it "is refused in the public demo, where everyone shares the account" do
    original = Rails.configuration.x.demo_mode
    Rails.configuration.x.demo_mode = true

    erase

    expect(response).to have_http_status(:forbidden)
    expect(error["code"]).to eq("demo_mode")
    expect(user.reload).not_to be_erased
  ensure
    Rails.configuration.x.demo_mode = original
  end

  it "limits how often the password can be tried with a token" do
    allow(Rails.cache).to receive(:increment).and_return(6)

    erase(password: "guess")

    expect(response).to have_http_status(:too_many_requests)
    expect(error["code"]).to eq("rate_limited")
  end
end
