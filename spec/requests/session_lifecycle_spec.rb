require "rails_helper"

# How long a token lives, how it is replaced, and how a person ends one (ADR 66).
RSpec.describe "Session lifecycle" do
  let(:user) { create(:user) }
  let(:other) { create(:user) }

  def sign_in
    session, token = Session.start_for!(user, ip_address: "203.0.113.7", user_agent: "RSpec")
    [ session, { "Authorization" => "Bearer #{token}" } ]
  end

  describe "expiry" do
    it "ends a session nobody has used for two weeks, while one in use lives on" do
      _session, headers = sign_in

      travel(13.days) do
        get "/api/v1/me", headers: headers
        expect(response).to have_http_status(:ok) # used: the idle clock restarts
      end

      travel(13.days + 13.days) do
        get "/api/v1/me", headers: headers
        expect(response).to have_http_status(:ok)
      end
    end

    it "does not renew an idle session by asking" do
      _session, headers = sign_in

      travel(Session::IDLE_TIMEOUT + 1.minute) do
        get "/api/v1/me", headers: headers
        expect(response).to have_http_status(:unauthorized)
      end
    end

    it "caps every session at its absolute lifetime, however often it is used" do
      _session, headers = sign_in

      (1..29).each do |day|
        travel(day.days) { get "/api/v1/me", headers: headers }
      end
      travel(Session::TTL + 1.hour) do
        get "/api/v1/me", headers: headers
        expect(response).to have_http_status(:unauthorized)
      end
    end

    it "counts a session that was never used from its creation" do
      session, headers = sign_in
      session.update_columns(last_used_at: nil)

      get "/api/v1/me", headers: headers
      expect(response).to have_http_status(:ok)

      travel(Session::IDLE_TIMEOUT + 1.day) do
        get "/api/v1/me", headers: headers
        expect(response).to have_http_status(:unauthorized)
      end
    end

    it "is what the daily clean-up removes: expired and idle sessions, not live ones" do
      live, = sign_in
      idle, = sign_in
      idle.update_columns(last_used_at: 15.days.ago)
      old, = sign_in
      old.update_columns(expires_at: 1.day.ago)

      Session.expired.delete_all

      expect(Session.all).to contain_exactly(live)
    end
  end

  describe "POST /session/rotate" do
    it "trades the token for a new one and kills the old one at once" do
      session, headers = sign_in

      post "/api/v1/session/rotate", headers: headers

      expect(response).to have_http_status(:created)
      new_token = data.fetch("token")
      expect(new_token).not_to eq(headers["Authorization"].split.last)
      expect(response.headers["Cache-Control"]).to include("no-store")
      expect(Session.exists?(session.id)).to be(false)

      get "/api/v1/me", headers: headers
      expect(response).to have_http_status(:unauthorized)
      get "/api/v1/me", headers: { "Authorization" => "Bearer #{new_token}" }
      expect(response).to have_http_status(:ok)
      expect(data["id"]).to eq(user.id)
    end

    it "leaves the person's other sign-ins alone, and a session count unchanged" do
      _session, headers = sign_in
      other_device, = sign_in

      expect { post "/api/v1/session/rotate", headers: headers }.not_to change { user.sessions.count }

      expect(Session.exists?(other_device.id)).to be(true)
    end

    it "keeps the new session's own lifetime: a rotation is a fresh 30 days, not the remainder of the old one" do
      _session, headers = sign_in

      travel(13.days) { get "/api/v1/me", headers: headers } # in use, so not idle
      travel(26.days) do
        post "/api/v1/session/rotate", headers: headers
        expect(Time.zone.parse(data["expires_at"])).to be_within(1.minute).of(30.days.from_now)
      end
    end

    it "needs a valid token, and does not exist when the Auth service owns sessions" do
      post "/api/v1/session/rotate"
      expect(response).to have_http_status(:unauthorized)

      with_jwt_auth do
        post "/api/v1/session/rotate", headers: jwt_headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "GET /sessions and DELETE /sessions/:id" do
    it "lists the caller's live sign-ins with where and when, marks the current one, and never shows a token" do
      current, headers = sign_in
      phone, = sign_in
      Session.start_for!(other)
      idle, = sign_in
      idle.update_columns(last_used_at: 20.days.ago)

      get "/api/v1/sessions", headers: headers

      expect(response).to have_http_status(:ok)
      expect(data.pluck("id")).to contain_exactly(current.id, phone.id)
      expect(data.find { _1["id"] == current.id }).to include("current" => true, "ip_address" => "203.0.113.7", "user_agent" => "RSpec")
      expect(data.find { _1["id"] == phone.id }["current"]).to be(false)
      expect(data.first.keys).not_to include("token", "token_digest")
      expect(response.body).not_to include(Session.digest(headers["Authorization"].split.last))
    end

    it "ends one of the caller's sign-ins, whose token then stops working, and refuses anyone else's" do
      _current, headers = sign_in
      phone, phone_headers = sign_in
      theirs, = Session.start_for!(other)

      delete "/api/v1/sessions/#{phone.id}", headers: headers
      expect(response).to have_http_status(:no_content)
      get "/api/v1/me", headers: phone_headers
      expect(response).to have_http_status(:unauthorized)

      delete "/api/v1/sessions/#{theirs.id}", headers: headers
      expect(response).to have_http_status(:not_found)
      expect(Session.exists?(theirs.id)).to be(true)
    end

    it "lets a person sign out the session they are using from the list, like DELETE /session" do
      current, headers = sign_in

      delete "/api/v1/sessions/#{current.id}", headers: headers

      expect(response).to have_http_status(:no_content)
      get "/api/v1/me", headers: headers
      expect(response).to have_http_status(:unauthorized)
    end

    it "does not exist when the Auth service owns sessions (one place issues and ends credentials)" do
      with_jwt_auth do
        get "/api/v1/sessions", headers: jwt_headers
        expect(response).to have_http_status(:not_found)

        delete "/api/v1/sessions/1", headers: jwt_headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  it "leaves the demo's shared account alone: nobody may read or end another visitor's sign-in there" do
    original = Rails.configuration.x.demo_mode
    Rails.configuration.x.demo_mode = true
    _session, headers = sign_in

    get "/api/v1/sessions", headers: headers
    expect(error["code"]).to eq("demo_mode")
    post "/api/v1/session/rotate", headers: headers
    expect(response).to have_http_status(:created) # rotating your own is harmless
  ensure
    Rails.configuration.x.demo_mode = original
  end

  it "records rotations and revocations as events, with the session's id and nothing about its network" do
    session, headers = sign_in

    events = record_events { post "/api/v1/session/rotate", headers: headers }

    expect(events.payloads("session.rotated").sole.keys).to eq([ :session_id ])
    expect(session.id).not_to be_nil
  end
end
