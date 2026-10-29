class WebhookDeliveryJob < ApplicationJob
  queue_as :webhooks

  # Receivers are often briefly down. 6 attempts with polynomial back-off spans ~an hour;
  # after that the failure stays visible in the delivery log (GET /webhooks/:id/deliveries).
  retry_on Webhooks::Deliverer::DeliveryFailed, wait: :polynomially_longer, attempts: 6

  def perform(delivery)
    return if delivery.delivered_at? || !delivery.webhook.active?

    Webhooks::Deliverer.new(delivery).call
  end
end
