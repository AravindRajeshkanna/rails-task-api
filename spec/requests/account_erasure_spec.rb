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

  # Where the Auth service owns the accounts (ADR 79): this application has no password to check, so it asks the Auth service, and the identity there is
  # deleted afterwards through the outbox (spec/services/account_erasure_spec.rb).
  describe "where the Auth service owns the accounts" do
    let(:jwt) { jwt_headers(sub: "auth-7", email: "ada@example.com", name: "Ada Lovelace").merge("Content-Type" => "application/json") }
    let(:check) { "https://auth.test/api/v1/credential_checks" }

    around { |example| with_jwt_auth { example.run } }

    before { api(:get, "/api/v1/me", headers: jwt) } # the first request makes the local user

    it "asks the Auth service whether the password is right, erases on its yes, and refuses the token that asked from then on" do
      asked = stub_request(:post, check).with(body: { email_address: "ada@example.com", password: "my-real-password" }.to_json).to_return(status: 204)

      erase(password: "my-real-password", as: jwt)

      expect(asked).to have_been_requested.once
      expect(response).to have_http_status(:no_content)
      expect(User.find_by!(auth_subject: "auth-7")).to be_erased
      api(:get, "/api/v1/me", headers: jwt) # the token has 15 minutes left; the person it names is gone
      expect(response).to have_http_status(:unauthorized)
      expect(User.where(erased_at: nil).where(auth_subject: "auth-7")).to be_empty
    end

    it "does not erase on the Auth service's no, and says what a local password check says" do
      stub_request(:post, check).to_return(status: 401)

      erase(password: "not-my-password", as: jwt)

      expect(response).to have_http_status(:unprocessable_content)
      expect(error["code"]).to eq("incorrect_password")
      expect(User.find_by!(auth_subject: "auth-7")).not_to be_erased
    end

    it "does not ask when there is no password, which is what a stolen token alone has" do
      delete "/api/v1/me", headers: jwt
      erase(password: "", as: jwt)

      expect(response).to have_http_status(:unprocessable_content)
      expect(error["code"]).to eq("incorrect_password")
      expect(a_request(:post, check)).not_to have_been_made
    end

    it "answers 503 and erases nothing when the Auth service cannot be reached or fails" do
      [ -> { stub_request(:post, check).to_timeout }, -> { stub_request(:post, check).to_raise(Errno::ECONNREFUSED) }, -> { stub_request(:post, check).to_return(status: 500) } ].each do |down|
        down.call

        erase(password: "my-real-password", as: jwt)

        expect(response).to have_http_status(:service_unavailable)
        expect(error["code"]).to eq("auth_unavailable")
        expect(User.find_by!(auth_subject: "auth-7")).not_to be_erased
      end
    end

    it "answers 429 when the Auth service says there have been too many attempts for this address" do
      stub_request(:post, check).to_return(status: 429)

      erase(password: "guess", as: jwt)

      expect(response).to have_http_status(:too_many_requests)
      expect(error["code"]).to eq("rate_limited")
      expect(User.find_by!(auth_subject: "auth-7")).not_to be_erased
    end

    it "still says what stands in the way" do
      create(:project, owner: User.find_by!(auth_subject: "auth-7"), name: "Moon shot")
      stub_request(:post, check).to_return(status: 204)

      erase(password: "my-real-password", as: jwt)

      expect(error["code"]).to eq("owns_projects")
      expect(User.find_by!(auth_subject: "auth-7")).not_to be_erased
    end
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
