require "rails_helper"

RSpec.describe "AUTH_MODE=jwt" do
  def me(headers) = api(:get, "/api/v1/me", headers: headers)

  around { |example| with_jwt_auth { example.run } }

  describe "authentication" do
    it "accepts a valid access token and creates the local user from its claims" do
      expect { me(jwt_headers(sub: "auth-1", email: "pat@example.com", name: "Pat Person")) }.to change(User, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(data).to include("name" => "Pat Person", "email_address" => "pat@example.com")
      expect(User.sole).to have_attributes(auth_subject: "auth-1", password_digest: nil)
    end

    it "reuses the local user on later requests and follows name and email changes" do
      me(jwt_headers(sub: "auth-1", email: "pat@example.com", name: "Pat Person"))
      expect { me(jwt_headers(sub: "auth-1", email: "pat@example.com", name: "Pat Q. Person")) }.not_to change(User, :count)

      expect(User.sole.name).to eq("Pat Q. Person")
    end

    it "lets the provisioned user work with projects like any other" do
      headers = jwt_headers(sub: "auth-1")
      api(:post, "/api/v1/projects", { name: "From JWT" }, headers: headers)

      expect(response).to have_http_status(:created)
      expect(Project.sole.owner.auth_subject).to eq("auth-1")
    end

    {
      "expired" => { exp: 1.minute.ago.to_i },
      "for another audience" => { aud: "billing" },
      "from another issuer" => { iss: "https://evil.test" },
      "without an expiry" => { exp: nil },
      "signed with an unknown key" => { key: OpenSSL::PKey::RSA.generate(2048) }
    }.each do |name, claims|
      it "rejects a token that is #{name}" do
        headers = { "Authorization" => "Bearer #{claims.key?(:exp) && claims[:exp].nil? ? JWT.encode({ iss: JwtHelpers::ISSUER, aud: 'task-api', sub: 'x', email: 'x@example.com' }, JwtHelpers.key, 'RS256', { kid: 'test-key' }) : jwt_for(**claims)}" }

        expect { me(headers) }.not_to change(User, :count)

        expect(response).to have_http_status(:unauthorized)
        expect(response.headers["WWW-Authenticate"]).to start_with("Bearer")
      end
    end

    it "no longer accepts this app's own session tokens" do
      _session, token = Session.start_for!(create(:user))

      me("Authorization" => "Bearer #{token}")

      expect(response).to have_http_status(:unauthorized)
    end

    it "answers 503 when the Auth service's keys cannot be fetched, not 401" do
      ExternalAuth.verifier = ServiceKit::JwtVerifier.new(issuer: JwtHelpers::ISSUER, audience: "task-api", jwks_url: "http://auth/jwks",
                                                          fetcher: ->(_) { raise ServiceKit::JwtVerifier::Unavailable, "down" })

      me(jwt_headers)

      expect(response).to have_http_status(:service_unavailable)
      expect(error["code"]).to eq("auth_unavailable")
      expect(response.headers["Retry-After"]).to eq("5")
    end
  end

  describe "linking accounts that existed before the migration" do
    let!(:legacy) { create(:user, email_address: "old@example.com", name: "Old Timer") }

    it "links by the legacy_id claim and keeps the user's data" do
      project = create(:project, owner: legacy)

      expect { me(jwt_headers(sub: "auth-9", email: "old@example.com", name: "Old Timer", legacy_id: legacy.id)) }.not_to change(User, :count)

      expect(response).to have_http_status(:ok)
      expect(data["id"]).to eq(legacy.id)
      expect(legacy.reload.auth_subject).to eq("auth-9")
      api(:get, "/api/v1/projects", headers: jwt_headers(sub: "auth-9", email: "old@example.com", legacy_id: legacy.id))
      expect(data.map { |p| p["id"] }).to eq([ project.id ])
    end

    it "never links by email alone: a new identity with a taken email is a conflict, not a takeover" do
      expect { me(jwt_headers(sub: "attacker", email: "old@example.com", name: "Mallory")) }.not_to change(User, :count)

      expect(response).to have_http_status(:conflict)
      expect(error["code"]).to eq("account_conflict")
      expect(legacy.reload.auth_subject).to be_nil
    end

    it "does not re-link an account that already belongs to another identity" do
      legacy.update_columns(auth_subject: "auth-9")

      me(jwt_headers(sub: "someone-else", email: "elsewhere@example.com", legacy_id: legacy.id))

      expect(legacy.reload.auth_subject).to eq("auth-9")
      expect(User.where(auth_subject: "someone-else").sole.id).not_to eq(legacy.id)
    end
  end

  describe "what this app no longer does" do
    it "does not issue credentials: sign-up, login and password reset are the Auth service's" do
      api(:post, "/api/v1/registrations", { name: "A", email_address: "a@example.com", password: "long-enough-pw" })
      expect(response).to have_http_status(:not_found)

      api(:post, "/api/v1/session", { email_address: "a@example.com", password: "x" })
      expect(response).to have_http_status(:not_found)

      api(:post, "/api/v1/passwords", { email_address: "a@example.com" })
      expect(response).to have_http_status(:not_found)
      expect(User.count).to eq(0)
    end

    it "leaves profile edits to the Auth service" do
      api(:patch, "/api/v1/me", { name: "Renamed" }, headers: jwt_headers)

      expect(response).to have_http_status(:conflict)
      expect(error["code"]).to eq("managed_by_auth_service")
    end
  end
end

RSpec.describe "AUTH_MODE=local (the default)" do
  it "ignores JWTs" do
    api(:get, "/api/v1/me", headers: jwt_headers)

    expect(response).to have_http_status(:unauthorized)
  end

  it "does not let a password-less projection user log in, even after rolling back from jwt mode" do
    create(:user, email_address: "proj@example.com").update_columns(password_digest: nil, auth_subject: "auth-1")

    api(:post, "/api/v1/session", { email_address: "proj@example.com", password: "anything-at-all" })

    expect(response).to have_http_status(:unauthorized)
  end

  it "still requires a password to register" do
    api(:post, "/api/v1/registrations", { name: "A", email_address: "a@example.com" })

    expect(response).to have_http_status(:unprocessable_content)
    expect(error["details"]).to have_key("password")
  end
end
