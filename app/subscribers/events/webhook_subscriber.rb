module Events
  # Records a WebhookDelivery for every active webhook listening to the event and
  # hands it to WebhookDeliveryJob. The payload is snapshotted here, so a retry
  # hours later still sends what happened, not what the record looks like now.
  class WebhookSubscriber < Subscriber
    private
      def handle(event)
        project_id = event.dig(:payload, :project_id)
        webhooks = Webhook.active.where(project_id: project_id).listening_to(event[:name]).to_a
        return if webhooks.empty?

        body = EventPayload.build(event)
        return unless body

        webhooks.each do |webhook|
          delivery = webhook.deliveries.create!(event: event[:name], payload: body)
          WebhookDeliveryJob.perform_later(delivery)
        end
      end
  end
end
