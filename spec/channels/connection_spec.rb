require "rails_helper"

RSpec.describe ApplicationCable::Connection do
  include ActionCable::Connection::TestCase::Behavior

  tests ApplicationCable::Connection

  let(:user) { create(:user) }
  let(:token) { Session.start_for!(user).last }

  it "accepts a bearer token header" do
    connect "/cable", headers: { "Authorization" => "Bearer #{token}" }

    expect(connection.current_user).to eq(user)
  end

  it "accepts a token query parameter for browsers" do
    connect "/cable?token=#{token}"

    expect(connection.current_user).to eq(user)
  end

  it "rejects missing, invalid and expired tokens" do
    token # issue it now, so it is the clock that makes it expire
    expect { connect "/cable" }.to raise_error(ActionCable::Connection::Authorization::UnauthorizedError)
    expect { connect "/cable?token=bogus" }.to raise_error(ActionCable::Connection::Authorization::UnauthorizedError)

    travel_to(31.days.from_now) do
      expect { connect "/cable?token=#{token}" }.to raise_error(ActionCable::Connection::Authorization::UnauthorizedError)
    end
  end
end
