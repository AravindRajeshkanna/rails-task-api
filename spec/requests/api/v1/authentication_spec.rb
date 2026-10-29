require "rails_helper"

RSpec.describe "Authentication" do
  def json_post(path, body, headers: {})
    post path, params: body.to_json, headers: { "Content-Type" => "application/json" }.merge(headers)
  end

  describe "POST /api/v1/registrations" do
    let(:valid_params) { { name: "Ada Lovelace", email_address: "Ada@Example.com", password: "analytical-engine" } }

    it "creates the user and returns a bearer token" do
      expect { json_post "/api/v1/registrations", valid_params }.to change(User, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(data["token"]).to be_present
      expect(data["user"]).to include("name" => "Ada Lovelace", "email_address" => "ada@example.com")
      expect(data["user"]).not_to have_key("password_digest")
      expect(data["expires_at"]).to be_present
    end

    it "returns a token that authenticates later requests" do
      json_post "/api/v1/registrations", valid_params

      get "/api/v1/me", headers: { "Authorization" => "Bearer #{data['token']}" }

      expect(response).to have_http_status(:ok)
      expect(data["email_address"]).to eq("ada@example.com")
    end

    it "reports validation errors" do
      create(:user, email_address: "ada@example.com")

      json_post "/api/v1/registrations", valid_params.merge(password: "short")

      expect(response).to have_http_status(:unprocessable_content)
      expect(error).to include("code" => "validation_failed", "status" => 422)
      expect(error["details"]).to include("email_address" => [ "has already been taken" ], "password" => [ a_string_matching(/too short/) ])
    end

    it "does not let clients mass-assign other attributes" do
      json_post "/api/v1/registrations", valid_params.merge(id: 999_999, password_digest: "x")

      expect(response).to have_http_status(:created)
      expect(User.find_by(email_address: "ada@example.com").id).not_to eq(999_999)
    end
  end

  describe "POST /api/v1/session" do
    let!(:user) { create(:user, email_address: "ada@example.com", password: "analytical-engine") }

    it "returns a token for valid credentials" do
      json_post "/api/v1/session", { email_address: "ADA@example.com", password: "analytical-engine" }

      expect(response).to have_http_status(:created)
      expect(data["token"]).to be_present
      expect(user.sessions.count).to eq(1)
    end

    it "records the client's IP and user agent" do
      json_post "/api/v1/session", { email_address: "ada@example.com", password: "analytical-engine" },
                headers: { "User-Agent" => "RSpec/1.0" }

      expect(user.sessions.sole).to have_attributes(user_agent: "RSpec/1.0", ip_address: "127.0.0.1")
    end

    it "rejects a wrong password without revealing whether the account exists" do
      json_post "/api/v1/session", { email_address: "ada@example.com", password: "wrong" }
      wrong_password = [ response.status, error ]

      json_post "/api/v1/session", { email_address: "nobody@example.com", password: "wrong" }
      unknown_email = [ response.status, error ]

      expect(wrong_password).to eq(unknown_email)
      expect(wrong_password.first).to eq(401)
      expect(error["code"]).to eq("invalid_credentials")
      expect(Session.count).to eq(0)
    end
  end

  describe "DELETE /api/v1/session" do
    it "revokes the token that made the request" do
      user = create(:user)
      headers = auth_headers(user)

      delete "/api/v1/session", headers: headers
      expect(response).to have_http_status(:no_content)

      get "/api/v1/me", headers: headers
      expect(response).to have_http_status(:unauthorized)
    end

    it "leaves the user's other sessions alone" do
      user = create(:user)
      other = auth_headers(user)
      current = auth_headers(user)

      delete "/api/v1/session", headers: current

      get "/api/v1/me", headers: other
      expect(response).to have_http_status(:ok)
    end
  end

  describe "bearer token handling" do
    it "returns 401 with a WWW-Authenticate header when no token is sent" do
      get "/api/v1/me"

      expect(response).to have_http_status(:unauthorized)
      expect(response.headers["WWW-Authenticate"]).to eq('Bearer realm="task_api"')
      expect(error).to include("code" => "unauthenticated", "status" => 401)
    end

    it "returns 401 for garbage and for the wrong scheme" do
      get "/api/v1/me", headers: { "Authorization" => "Bearer not-a-real-token" }
      expect(response).to have_http_status(:unauthorized)

      get "/api/v1/me", headers: { "Authorization" => "Basic dXNlcjpwYXNz" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 401 once the session has expired" do
      user = create(:user)
      headers = auth_headers(user)

      travel_to(31.days.from_now) do
        get "/api/v1/me", headers: headers
        expect(response).to have_http_status(:unauthorized)
      end
    end

    it "protects every other endpoint" do
      get "/api/v1/projects"
      expect(response).to have_http_status(:unauthorized)

      post "/api/v1/projects/1/tasks"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "password reset" do
    let!(:user) { create(:user, email_address: "ada@example.com") }

    it "emails a reset link to the front end for a known address" do
      expect { json_post "/api/v1/passwords", { email_address: "ada@example.com" } }
        .to have_enqueued_mail(PasswordsMailer, :reset).with(user)

      expect(response).to have_http_status(:accepted)
    end

    it "answers identically for an unknown address and sends nothing" do
      expect { json_post "/api/v1/passwords", { email_address: "nobody@example.com" } }
        .not_to have_enqueued_mail(PasswordsMailer, :reset)

      expect(response).to have_http_status(:accepted)
      expect(response.body).to be_blank
    end

    it "builds the email around a front-end URL containing a working token" do
      mail = PasswordsMailer.reset(user)

      url = mail.body.to_s[%r{http\S+reset-password\?token=\S+}]
      expect(url).to start_with("#{Rails.configuration.x.frontend_url}/reset-password?token=")
      expect(mail.to).to eq([ "ada@example.com" ])

      token = CGI.unescape(url.split("token=").last)
      expect(User.find_by_password_reset_token!(token)).to eq(user)
    end

    it "sets a new password with a valid token and signs out every device" do
      auth_headers(user)
      token = user.password_reset_token

      patch "/api/v1/passwords/#{CGI.escape(token)}",
            params: { password: "a-brand-new-password" }.to_json,
            headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:no_content)
      expect(user.sessions.count).to eq(0)
      expect(User.authenticate_by(email_address: "ada@example.com", password: "a-brand-new-password")).to eq(user)
    end

    it "rejects an invalid or expired token" do
      patch "/api/v1/passwords/bogus", params: { password: "a-brand-new-password" }.to_json,
                                       headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(error["code"]).to eq("invalid_token")

      token = user.password_reset_token
      travel_to(1.hour.from_now) do
        patch "/api/v1/passwords/#{CGI.escape(token)}", params: { password: "a-brand-new-password" }.to_json,
                                                        headers: { "Content-Type" => "application/json" }
        expect(response).to have_http_status(:unprocessable_content)
        expect(error["code"]).to eq("invalid_token")
      end
    end

    it "rejects a weak new password" do
      patch "/api/v1/passwords/#{CGI.escape(user.password_reset_token)}",
            params: { password: "short" }.to_json, headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(error["details"]).to have_key("password")
    end
  end

  describe "GET/PATCH /api/v1/me" do
    let(:user) { create(:user, name: "Ada") }

    it "shows and updates the current user" do
      get "/api/v1/me", headers: auth_headers(user)
      expect(data).to include("id" => user.id, "name" => "Ada")

      patch "/api/v1/me", params: { name: "Ada L." }.to_json,
                          headers: auth_headers(user).merge("Content-Type" => "application/json")
      expect(data["name"]).to eq("Ada L.")
      expect(user.reload.name).to eq("Ada L.")
    end

    it "ignores attempts to change the email address or password through this endpoint" do
      patch "/api/v1/me", params: { email_address: "evil@example.com", password: "hacked-password" }.to_json,
                          headers: auth_headers(user).merge("Content-Type" => "application/json")

      expect(user.reload.email_address).not_to eq("evil@example.com")
      expect(User.authenticate_by(email_address: user.email_address, password: "hacked-password")).to be_nil
    end
  end

  describe "avatar" do
    let(:user) { create(:user) }

    it "uploads, serves a signed URL, and removes an avatar" do
      put "/api/v1/me/avatar", params: { avatar: fixture_file_upload("pixel.png", "image/png") }, headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(data["avatar_url"]).to match(%r{\Ahttp://www\.example\.com/rails/active_storage/blobs/redirect/.+/pixel\.png\z})
      expect(user.reload.avatar).to be_attached

      delete "/api/v1/me/avatar", headers: auth_headers(user)
      expect(response).to have_http_status(:no_content)
      perform_enqueued_jobs
      expect(user.reload.avatar).not_to be_attached
    end

    it "rejects files that are not images" do
      put "/api/v1/me/avatar", params: { avatar: fixture_file_upload("notes.txt", "text/plain") }, headers: auth_headers(user)

      expect(response).to have_http_status(:unprocessable_content)
      expect(error["details"]["avatar"]).to include("must be a PNG, JPEG or WebP image")
      expect(user.reload.avatar).not_to be_attached
    end

    it "requires the avatar field" do
      put "/api/v1/me/avatar", params: { avatar: "not-a-file" }, headers: auth_headers(user)

      expect(response).to have_http_status(:bad_request)
      expect(error["code"]).to eq("parameter_missing")
    end
  end
end
