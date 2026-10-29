require "rails_helper"

# One person's whole relationship with the API, end to end over HTTP: the individual pieces are
# tested in spec/requests/api/v1/authentication_spec.rb; this proves they fit together.
RSpec.describe "Authentication journey" do
  def bearer(token) = { "Authorization" => "Bearer #{token}" }

  it "sign up, work, lose the password, reset it, and be signed out everywhere" do
    # Sign up and use the token straight away.
    api :post, "/api/v1/registrations", { name: "Ada", email_address: "ada@example.com", password: "first-password-1" }
    expect(response).to have_http_status(:created)
    phone_token = data.fetch("token")

    api :post, "/api/v1/projects", { name: "Analytical Engine" }, headers: bearer(phone_token)
    expect(response).to have_http_status(:created)
    project_id = data.fetch("id")

    # A second device signs in with the same password.
    api :post, "/api/v1/session", { email_address: "ADA@example.com ", password: "first-password-1" }
    expect(response).to have_http_status(:created)
    laptop_token = data.fetch("token")
    expect(laptop_token).not_to eq(phone_token)

    # Signing out the laptop leaves the phone working.
    api :delete, "/api/v1/session", headers: bearer(laptop_token)
    expect(response).to have_http_status(:no_content)
    api :get, "/api/v1/me", headers: bearer(laptop_token)
    expect(response).to have_http_status(:unauthorized)
    api :get, "/api/v1/projects/#{project_id}", headers: bearer(phone_token)
    expect(response).to have_http_status(:ok)

    # Forgot the password: ask for a reset (the answer never says whether the address exists) ...
    user = User.find_by!(email_address: "ada@example.com")
    expect { api :post, "/api/v1/passwords", { email_address: "ada@example.com" } }.to have_enqueued_mail(PasswordsMailer, :reset)
    expect(response).to have_http_status(:accepted)

    # ... and use the token from the email to choose a new one.
    api :patch, "/api/v1/passwords/#{CGI.escape(user.password_reset_token)}", { password: "second-password-2" }
    expect(response).to have_http_status(:no_content)

    # Every existing session is gone, the old password no longer works, the new one does.
    api :get, "/api/v1/me", headers: bearer(phone_token)
    expect(response).to have_http_status(:unauthorized)
    api :post, "/api/v1/session", { email_address: "ada@example.com", password: "first-password-1" }
    expect(response).to have_http_status(:unauthorized)
    api :post, "/api/v1/session", { email_address: "ada@example.com", password: "second-password-2" }
    expect(response).to have_http_status(:created)

    # Her data survived all of it.
    api :get, "/api/v1/projects/#{project_id}", headers: bearer(data.fetch("token"))
    expect(data).to include("name" => "Analytical Engine")
  end

  it "does not let a reset token be used twice" do
    user = create(:user)
    token = user.password_reset_token

    api :patch, "/api/v1/passwords/#{CGI.escape(token)}", { password: "second-password-2" }
    expect(response).to have_http_status(:no_content)

    api :patch, "/api/v1/passwords/#{CGI.escape(token)}", { password: "third-password-3" }
    expect(response).to have_http_status(:unprocessable_content)
  end
end
