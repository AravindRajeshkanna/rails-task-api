require "rails_helper"

# POST /api/v1/credential_checks: the Task API asking whether a password is a person's, for DELETE /me (ADR 79).
RSpec.describe "Credential checks", type: :request do
  let!(:user) { create(:user, email_address: "pat@example.com") }

  it "says yes, with nothing in the answer and no token issued" do
    expect { post_json("/api/v1/credential_checks", { email_address: "pat@example.com", password: "correct-horse-battery" }) }.not_to change(RefreshToken, :count)

    expect(response).to have_http_status(:no_content)
    expect(response.body).to be_empty
    expect(response.headers["Cache-Control"]).to eq("private, no-store")
  end

  it "reads the address the way signing in does" do
    post_json("/api/v1/credential_checks", { email_address: "  Pat@Example.com ", password: "correct-horse-battery" })

    expect(response).to have_http_status(:no_content)
  end

  it "says no to a wrong password and to an address it does not know, in the same words" do
    post_json("/api/v1/credential_checks", { email_address: "pat@example.com", password: "not-my-password" })
    wrong = [ response.status, json ]
    post_json("/api/v1/credential_checks", { email_address: "nobody@example.com", password: "correct-horse-battery" })

    expect([ response.status, json ]).to eq(wrong)
    expect(wrong.first).to eq(401)
    expect(error["code"]).to eq("invalid_credentials")
  end

  it "says no to an empty password" do
    post_json("/api/v1/credential_checks", { email_address: "pat@example.com", password: "" })

    expect(response).to have_http_status(:unauthorized)
  end

  it "limits the attempts on one address, whoever asks, with the answer signing in gives" do
    allow(Rails.cache).to receive(:increment).and_return(6)

    post_json("/api/v1/credential_checks", { email_address: "pat@example.com", password: "guess" })

    expect(response).to have_http_status(:too_many_requests)
    expect(error["code"]).to eq("rate_limited")
  end

  it "counts the attempts of each address apart: the limit is on the address, not on who asked" do
    allow(Rails.cache).to receive(:increment).and_return(1)

    post_json("/api/v1/credential_checks", { email_address: "Pat@Example.com ", password: "guess" })

    expect(Rails.cache).to have_received(:increment).with(a_string_including("pat@example.com"), 1, expires_in: 1.minute)
  end

  it "is not one of the paths the ingress sends the public here" do
    values = YAML.safe_load_file(Rails.root.join("../../deploy/helm/values/auth.yaml"))

    expect(values.dig("ingress", "paths").map { |entry| entry["path"] }).not_to include(a_string_matching(/credential/))
    expect(values.dig("ingress", "paths").map { |entry| entry["path"] }).to include("/api/v1/session")
  end
end
