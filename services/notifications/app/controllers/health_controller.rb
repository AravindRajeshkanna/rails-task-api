class HealthController < ApplicationController
  def show
    if Notifications::Heartbeat.healthy?
      render json: { status: "ok", last_poll_seconds_ago: Notifications::Heartbeat.age&.round }
    else
      render json: { status: "stalled", last_poll_seconds_ago: Notifications::Heartbeat.age&.round }, status: :service_unavailable
    end
  end
end
