class WebhookDeliveryJob < ApplicationJob
  queue_as :webhooks

  # Receivers are often briefly down. 6 attempts with polynomial back-off spans ~an hour;
  # after that the failure stays visible in the delivery log (GET /webhooks/:id/deliveries).
  retry_on Webhooks::Deliverer::DeliveryFailed, wait: :polynomially_longer, attempts: 6

  # Signing needs the webhook's secret, which needs KMS to unwrap its key (unless it is cached). KMS being throttled or briefly unreachable is not the
  # receiver's fault and not a reason to lose the event: wait and try again, longer than for a receiver (the same ~hour, over more attempts).
  retry_on KmsEncryption::Unavailable, wait: :polynomially_longer, attempts: 8

  def perform(delivery)
    return if delivery.delivered_at? || !delivery.webhook.active?

    Webhooks::Deliverer.new(delivery).call
  end
end
