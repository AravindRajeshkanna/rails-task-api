require "rails_helper"

RSpec.describe Session do
  let(:user) { create(:user) }

  describe ".start_for!" do
    it "returns the session and a plaintext token, persisting only the digest" do
      session, token = Session.start_for!(user, ip_address: "203.0.113.9", user_agent: "rspec")

      expect(token.length).to eq(32)
      expect(session.token_digest).to eq(Session.digest(token))
      expect(session.token_digest).not_to include(token)
      expect(session).to have_attributes(user: user, ip_address: "203.0.113.9", user_agent: "rspec")
      expect(session.expires_at).to be_within(1.minute).of(30.days.from_now)
    end
  end

  describe ".authenticate" do
    let!(:started) { Session.start_for!(user) }
    let(:session) { started.first }
    let(:token) { started.last }

    it "finds the session for a valid token" do
      expect(Session.authenticate(token)).to eq(session)
    end

    it "returns nil for unknown, blank or expired tokens" do
      expect(Session.authenticate("wrong")).to be_nil
      expect(Session.authenticate(nil)).to be_nil
      expect(Session.authenticate("")).to be_nil

      travel_to(31.days.from_now) { expect(Session.authenticate(token)).to be_nil }
    end

    it "refreshes last_used_at at most every few minutes" do
      session.update_column(:last_used_at, 10.minutes.ago)
      Session.authenticate(token)
      expect(session.reload.last_used_at).to be_within(5.seconds).of(Time.current)

      expect { Session.authenticate(token) }.not_to(change { session.reload.updated_at })
      expect { Session.authenticate(token) }.not_to(change { session.reload.last_used_at })
    end
  end

  describe "scopes" do
    it "splits active and expired sessions" do
      active, = Session.start_for!(user)
      expired, = Session.start_for!(user)
      expired.update!(expires_at: 1.minute.ago)

      expect(Session.active).to contain_exactly(active)
      expect(Session.expired).to contain_exactly(expired)
    end
  end
end
