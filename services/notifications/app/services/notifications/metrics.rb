module Notifications
  module Metrics
    PROCESSED = ServiceKit::Metrics.counter(:notifications_processed_total, "Events handled by type and outcome", %i[type outcome])
    DELIVERIES = ServiceKit::Metrics.counter(:notifications_deliveries_total, "Messages sent by channel", %i[channel])
    POLL_AGE = ServiceKit::Metrics.gauge(:notifications_consumer_last_poll_age_seconds, "Seconds since the consumer last finished polling")

    def self.collect! = POLL_AGE.set(Heartbeat.age || -1)
  end
end
