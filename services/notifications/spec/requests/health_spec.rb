require "rails_helper"

RSpec.describe "Health and metrics", type: :request do
  it "is healthy when no consumer runs in this process (web only)" do
    get "/healthz"

    expect(response).to have_http_status(:ok)
  end

  it "is healthy while the consumer keeps polling and unhealthy once it stalls" do
    Notifications::Heartbeat.enable!
    get "/healthz"
    expect(response).to have_http_status(:ok)

    travel_to(Notifications::Heartbeat::STALE_AFTER.seconds.from_now) do
      allow(Process).to receive(:clock_gettime).and_call_original
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(Process.clock_gettime(Process::CLOCK_MONOTONIC) + Notifications::Heartbeat::STALE_AFTER + 1)
      get "/healthz"
    end

    expect(response).to have_http_status(:service_unavailable)
    expect(JSON.parse(response.body)["status"]).to eq("stalled")
  end

  it "exposes metrics, including how long ago the consumer last polled" do
    Notifications::Heartbeat.enable!

    get "/metrics"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("notifications_consumer_last_poll_age_seconds", "service_http_requests_total")
  end
end
