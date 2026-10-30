# Deletes webhook deliveries older than their retention. Each holds a snapshot of the event it carried, so left alone the table grows with
# every event times every webhook, and keeps people's task and comment text long after the task itself is gone.
class PurgeWebhookDeliveriesJob < ApplicationJob
  queue_as :low

  def perform
    WebhookDelivery.expired.in_batches(of: 5_000).delete_all
  end
end
