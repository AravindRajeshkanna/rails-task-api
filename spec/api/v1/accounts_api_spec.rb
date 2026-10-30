require "swagger_helper"

RSpec.describe "Authentication & account API", type: :request do
  ref = OpenapiSchemas.method(:ref)
  envelope = OpenapiSchemas.method(:envelope)

  path "/api/v1/registrations" do
    post "Sign up" do
      tags "Authentication"
      description "Creates an account and signs in. Limited to 10 attempts per hour per IP."
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: { name: { type: :string }, email_address: { type: :string, format: :email }, password: { type: :string, minLength: 8 } },
        required: %i[name email_address password]
      }

      response "201", "Account created" do
        schema envelope.call(ref.call("Session"))
        let(:body) { { name: "Ada Lovelace", email_address: "ada@example.com", password: "analytical-engine" } }
        run_test!
      end

      response "422", "Validation failed" do
        schema ref.call("Error")
        let(:body) { { name: "", email_address: "nope", password: "short" } }
        run_test!
      end
    end
  end

  path "/api/v1/session" do
    post "Sign in" do
      tags "Authentication"
      description "Exchanges credentials for a bearer token. Limited to 10 attempts per 3 minutes per IP and 5 per minute per account."
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: { email_address: { type: :string }, password: { type: :string } },
        required: %i[email_address password]
      }
      let!(:user) { create(:user, email_address: "ada@example.com", password: "analytical-engine") }

      response "201", "Signed in" do
        schema envelope.call(ref.call("Session"))
        let(:body) { { email_address: "ada@example.com", password: "analytical-engine" } }
        run_test!
      end

      response "401", "Invalid credentials" do
        schema ref.call("Error")
        let(:body) { { email_address: "ada@example.com", password: "wrong" } }
        run_test!
      end
    end

    delete "Sign out" do
      tags "Authentication"
      description "Revokes the token used for the request."
      security [ { bearer_auth: [] } ]
      let(:Authorization) { auth_headers(create(:user))["Authorization"] }

      response "204", "Signed out" do
        run_test!
      end

      response "401", "Missing or invalid token" do
        schema ref.call("Error")
        let(:Authorization) { "Bearer nope" }
        run_test!
      end
    end
  end

  path "/api/v1/session/rotate" do
    post "Rotate the token" do
      tags "Authentication"
      description "Trades the token used for the request for a new one (same person and device, new secret, a fresh 30 days). The old token stops " \
                  "working at once, so a token that leaked is useless after the next rotation. Limited to 30 a hour. A sign-in unused for 14 days " \
                  "expires on its own, so a client that goes quiet has to sign in again. Not available when the Auth service issues tokens (404)."
      security [ { bearer_auth: [] } ]
      produces "application/json"
      let(:Authorization) { auth_headers(create(:user))["Authorization"] }

      response "201", "A new token; the one used for this request is dead" do
        schema envelope.call(ref.call("Session"))
        run_test! do
          get "/api/v1/me", headers: { "Authorization" => request.headers["Authorization"] }
          expect(response).to have_http_status(:unauthorized)
        end
      end

      response "401", "Missing, invalid, expired or idle token" do
        schema ref.call("Error")
        let(:Authorization) { "Bearer nope" }
        run_test!
      end
    end
  end

  path "/api/v1/sessions" do
    get "My sign-ins" do
      tags "Authentication"
      description "Where the caller is signed in: when, from which address and client, last use, and which one this request used. Newest use first."
      security [ { bearer_auth: [] } ]
      produces "application/json"
      parameter name: :limit, in: :query, type: :integer, required: false
      let(:user) { create(:user) }
      let(:Authorization) { auth_headers(user)["Authorization"] }
      before { Session.start_for!(user, user_agent: "Old laptop") }

      response "200", "The caller's live sign-ins" do
        schema envelope.call(ref.call("UserSession"), list: true)
        run_test! { expect(data.size).to eq(2) }
      end

      response "401", "Not signed in" do
        schema ref.call("Error")
        let(:Authorization) { nil }
        run_test!
      end
    end
  end

  path "/api/v1/sessions/{id}" do
    delete "End a sign-in" do
      tags "Authentication"
      description "Revokes one of the caller's own sign-ins (a lost phone, a forgotten laptop). Someone else's id answers 404."
      security [ { bearer_auth: [] } ]
      parameter name: :id, in: :path, type: :integer
      let(:user) { create(:user) }
      let(:Authorization) { auth_headers(user)["Authorization"] }
      let(:id) { Session.start_for!(user).first.id }

      response "204", "Ended" do
        run_test!
      end

      response "404", "Not one of yours" do
        schema ref.call("Error")
        let(:id) { Session.start_for!(create(:user)).first.id }
        run_test!
      end
    end
  end

  path "/api/v1/passwords" do
    post "Request a password reset" do
      tags "Authentication"
      description "Emails a link to the front end. Always answers 202, whether or not the address exists."
      consumes "application/json"
      parameter name: :body, in: :body, schema: { type: :object, properties: { email_address: { type: :string } }, required: [ :email_address ] }

      response "202", "Accepted" do
        let(:body) { { email_address: "anyone@example.com" } }
        run_test!
      end
    end
  end

  path "/api/v1/passwords/{token}" do
    patch "Choose a new password" do
      tags "Authentication"
      description "Sets a new password using the emailed token (valid 15 minutes) and signs out every device."
      consumes "application/json"
      produces "application/json"
      parameter name: :token, in: :path, type: :string
      parameter name: :body, in: :body, schema: { type: :object, properties: { password: { type: :string, minLength: 8 } }, required: [ :password ] }
      let(:user) { create(:user) }

      response "204", "Password changed" do
        let(:token) { CGI.escape(user.password_reset_token) }
        let(:body) { { password: "a-brand-new-password" } }
        run_test!
      end

      response "422", "Invalid or expired token, or weak password" do
        schema ref.call("Error")
        let(:token) { "expired" }
        let(:body) { { password: "a-brand-new-password" } }
        run_test!
      end
    end
  end

  path "/api/v1/me" do
    let(:user) { create(:user) }
    let(:Authorization) { auth_headers(user)["Authorization"] }

    get "Current user" do
      tags "Account"
      security [ { bearer_auth: [] } ]
      produces "application/json"

      response "200", "The signed-in user" do
        schema envelope.call(ref.call("User"))
        run_test!
      end

      response "401", "Not signed in" do
        schema ref.call("Error")
        let(:Authorization) { nil }
        run_test!
      end
    end

    delete "Erase my account" do
      tags "Account"
      description "Ends the account: the name, address, password, sign-ins, memberships, notifications and avatar go, and the row stays as \"Deleted user\" so tasks, comments " \
                  "and the audit trail keep pointing at something. Needs the current password. Refused with 422 while you own a project that is not archived (`owns_projects`) " \
                  "or are the last owner of an organization (`last_organization_owner`). 409 when the Auth service owns accounts; refused in the public demo. 5 tries an hour."
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: { type: :object, properties: { password: { type: :string } }, required: [ :password ] }
      let(:body) { { password: user.password } }

      response "204", "Erased; the token used is dead" do
        run_test! { expect(user.reload).to be_erased }
      end

      response "422", "Wrong password, or something to hand over first" do
        schema ref.call("Error")
        let(:body) { { password: "wrong" } }
        run_test!
      end
    end

    patch "Update profile" do
      tags "Account"
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: { type: :object, properties: { name: { type: :string } } }

      response "200", "Updated" do
        schema envelope.call(ref.call("User"))
        let(:body) { { name: "New Name" } }
        run_test!
      end

      response "422", "Validation failed" do
        schema ref.call("Error")
        let(:body) { { name: "" } }
        run_test!
      end
    end
  end

  path "/api/v1/me/avatar" do
    let(:Authorization) { auth_headers(create(:user))["Authorization"] }

    put "Upload avatar" do
      tags "Account"
      description "multipart/form-data with an `avatar` image field (PNG, JPEG or WebP, up to 2 MB)."
      security [ { bearer_auth: [] } ]
      consumes "multipart/form-data"
      produces "application/json"
      parameter name: :avatar, in: :formData, required: true,
                schema: { type: :object, properties: { avatar: { type: :string, format: :binary } }, required: [ :avatar ] }

      response "200", "Avatar saved; `avatar_url` is a signed URL" do
        schema envelope.call(ref.call("User"))
        let(:avatar) { fixture_file_upload("pixel.png", "image/png") }
        run_test! { expect(data["avatar_url"]).to include("/rails/active_storage/blobs/") }
      end

      response "422", "Not an acceptable image" do
        schema ref.call("Error")
        let(:avatar) { fixture_file_upload("notes.txt", "text/plain") }
        run_test!
      end
    end

    delete "Remove avatar" do
      tags "Account"
      security [ { bearer_auth: [] } ]

      response "204", "Removed" do
        run_test!
      end
    end
  end
end
