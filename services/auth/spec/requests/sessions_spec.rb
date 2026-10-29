require "rails_helper"

RSpec.describe "Registration, sessions and tokens", type: :request do
  let!(:user) { create(:user, email_address: "pat@example.com", name: "Pat Person") }

  describe "POST /api/v1/registrations" do
    it "creates the account and signs it in, with a token the other services can verify" do
      post_json("/api/v1/registrations", { name: "Sam New", email_address: "Sam@Example.com ", password: "long-enough-pw" })

      expect(response).to have_http_status(:created)
      new_user = User.find_by!(email_address: "sam@example.com")
      claims = verifier.verify!(data["token"])
      expect(claims).to include("sub" => new_user.uid, "email" => "sam@example.com", "name" => "Sam New", "iss" => Rails.configuration.x.auth.issuer, "aud" => "task-api")
      expect(claims).not_to have_key("legacy_id")
      expect(data).to include("refresh_token", "expires_at", "refresh_expires_at")
      expect(data["user"]).to include("id" => new_user.uid, "email_address" => "sam@example.com")
    end

    it "validates like the monolith did" do
      post_json("/api/v1/registrations", { name: "", email_address: "pat@example.com", password: "short" })

      expect(response).to have_http_status(:unprocessable_content)
      expect(error["details"].keys).to include("name", "email_address", "password")
    end

    it "never returns the password digest" do
      post_json("/api/v1/registrations", { name: "Sam", email_address: "sam@example.com", password: "long-enough-pw" })

      expect(response.body).not_to include("password_digest")
    end
  end

  describe "POST /api/v1/session" do
    it "signs in and issues a 15 minute access token" do
      travel_to(Time.utc(2026, 10, 29, 12)) do
        post_json("/api/v1/session", { email_address: "pat@example.com", password: "correct-horse-battery" })

        expect(response).to have_http_status(:created)
        claims = verifier.verify!(data["token"])
        expect(claims["exp"] - claims["iat"]).to eq(15.minutes.to_i)
        expect(Time.iso8601(data["expires_at"])).to eq(Time.utc(2026, 10, 29, 12, 15))
      end
    end

    it "carries the pre-migration id so the monolith can link the account" do
      user.update!(legacy_id: 41)

      claims = verifier.verify!(sign_in(user)["token"])

      expect(claims["legacy_id"]).to eq(41)
    end

    it "rejects bad credentials the same way for unknown emails and wrong passwords" do
      post_json("/api/v1/session", { email_address: "pat@example.com", password: "wrong" })
      wrong_password = [ response.status, json ]
      post_json("/api/v1/session", { email_address: "nobody@example.com", password: "wrong" })

      expect([ response.status, json ]).to eq(wrong_password)
      expect(response).to have_http_status(:unauthorized)
      expect(error["code"]).to eq("invalid_credentials")
    end

    it "throttles guessing" do
      allow(Rails.cache).to receive(:increment).and_return(11)

      post_json("/api/v1/session", { email_address: "pat@example.com", password: "guess" })

      expect(response).to have_http_status(:too_many_requests)
      expect(error["code"]).to eq("rate_limited")
    end
  end

  describe "refresh tokens" do
    it "rotates: the new pair works, the old refresh token does not" do
      first = sign_in(user)

      post_json("/api/v1/session/refresh", { refresh_token: first["refresh_token"] })
      second = data

      expect(response).to have_http_status(:ok)
      expect(second["refresh_token"]).not_to eq(first["refresh_token"])
      expect(verifier.verify!(second["token"])["sub"]).to eq(user.uid)
      post_json("/api/v1/session/refresh", { refresh_token: second["refresh_token"] })
      expect(response).to have_http_status(:ok)
    end

    it "treats reuse of a rotated token as theft and ends every session from that sign-in" do
      first = sign_in(user)
      post_json("/api/v1/session/refresh", { refresh_token: first["refresh_token"] })
      legitimate = data

      post_json("/api/v1/session/refresh", { refresh_token: first["refresh_token"] }) # the thief replays the old token

      expect(response).to have_http_status(:unauthorized)
      expect(error["code"]).to eq("refresh_token_reused")
      post_json("/api/v1/session/refresh", { refresh_token: legitimate["refresh_token"] }) # the owner is signed out too
      expect(response).to have_http_status(:unauthorized)
    end

    it "does not touch the user's other sign-ins when one family is revoked" do
      laptop = sign_in(user)
      phone = sign_in(user)
      post_json("/api/v1/session/refresh", { refresh_token: laptop["refresh_token"] })
      post_json("/api/v1/session/refresh", { refresh_token: laptop["refresh_token"] }) # replay on the laptop family

      post_json("/api/v1/session/refresh", { refresh_token: phone["refresh_token"] })

      expect(response).to have_http_status(:ok)
    end

    it "rejects expired, unknown and missing tokens" do
      token = sign_in(user)["refresh_token"]

      travel_to(31.days.from_now) { post_json("/api/v1/session/refresh", { refresh_token: token }) }
      expect(response).to have_http_status(:unauthorized)
      expect(error["code"]).to eq("invalid_refresh_token")

      post_json("/api/v1/session/refresh", { refresh_token: "unknown" })
      expect(error["code"]).to eq("invalid_refresh_token")

      post_json("/api/v1/session/refresh", {})
      expect(response).to have_http_status(:bad_request)
    end

    it "stores only a digest" do
      token = sign_in(user)["refresh_token"]

      expect(RefreshToken.pluck(:token_digest)).not_to include(token)
      expect(RefreshToken.sole.token_digest).to eq(RefreshToken.digest(token))
    end
  end

  describe "DELETE /api/v1/session" do
    it "ends the sign-in and is safe to repeat" do
      token = sign_in(user)["refresh_token"]

      2.times do
        delete_json("/api/v1/session", { refresh_token: token })
        expect(response).to have_http_status(:no_content)
      end

      post_json("/api/v1/session/refresh", { refresh_token: token })
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
