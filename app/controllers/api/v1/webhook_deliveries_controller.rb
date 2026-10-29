module Api
  module V1
    # Delivery log for one webhook, newest first. Useful for debugging a receiver.
    class WebhookDeliveriesController < BaseController
      def index
        webhook = policy_scope(Webhook).find(params[:webhook_id])
        authorize webhook, :show?
        records, meta = paginate(webhook.deliveries.recent)
        render_resource WebhookDeliveryResource, records, meta: meta
      end
    end
  end
end
