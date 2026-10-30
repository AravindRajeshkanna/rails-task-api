require "rails_helper"

RSpec.describe NotificationsChannel, type: :channel do
  let(:user) { create(:user) }

  it "streams the signed-in person's own inbox, and nobody else's" do
    stub_connection current_user: user

    subscribe

    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_from(Notification.stream_name(user.id))
    expect(subscription).not_to have_stream_from(Notification.stream_name(user.id + 1))
  end
end
