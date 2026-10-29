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
