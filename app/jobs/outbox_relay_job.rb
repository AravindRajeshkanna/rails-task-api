# Publishes pending outbox events (Events::OutboxRelay). Woken after a commit that wrote one, and swept every
# minute (config/recurring.yml). Only one runs at a time: a wake-up while one is running is dropped, because
# the running one (or the next sweep) will find the new row.
class OutboxRelayJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: "outbox_relay", duration: 1.minute, on_conflict: :discard

  # Never lets a failure to enqueue reach the request that wrote the event: the row is committed, and the sweep finds it.
  def self.wake
    perform_later
  rescue => error
    Rails.error.report(error, handled: true, severity: :warning, context: { job: name })
  end

  def perform
    Events::OutboxRelay.call
  end
end
