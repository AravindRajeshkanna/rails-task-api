module AuthService
  module Metrics
    ERASURES = ServiceKit::Metrics.counter(:auth_erasures_total, "Erasure events handled, by outcome (erased, unknown, ignored, failed)", %i[outcome])
    POLL_AGE = ServiceKit::Metrics.gauge(:auth_erasure_consumer_last_poll_age_seconds, "Seconds since the erasure consumer last finished polling (-1: not running)")

    def self.collect! = POLL_AGE.set(ErasureConsumer.last_poll_age || -1)
  end
end
