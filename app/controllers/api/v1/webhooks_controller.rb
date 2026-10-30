module Api
  module V1
    # Project admins register URLs that receive signed JSON events (see Webhooks::Deliverer).
    class WebhooksController < BaseController
      idempotent :create # a retried POST with the same Idempotency-Key answers the first one's response (Idempotency)
      before_action :set_project, only: %i[index create]
      before_action :set_webhook, only: %i[show update destroy]

      def index
        authorize @project, :manage_webhooks?
        webhooks = policy_scope(@project.webhooks).order(:created_at, :id)
        records, meta = paginate(webhooks)
        render_resource WebhookResource, records, meta: meta
      end

      def show
        authorize @webhook
        render_resource WebhookResource, @webhook
      end

      # The signing secret is returned here, once.
      def create
        webhook = @project.webhooks.build
        authorize webhook
        webhook.update!(webhook_params)
        render_resource WebhookWithSecretResource, webhook, status: :created
      end

      def update
        authorize @webhook
        @webhook.update!(webhook_params)
        render_resource WebhookResource, @webhook
      end

      def destroy
        authorize @webhook
        @webhook.destroy!
        head :no_content
      end

      private
        def set_project
          @project = policy_scope(Project).kept.find(params[:project_id])
        end

        def set_webhook
          @webhook = policy_scope(Webhook).find(params[:id])
        end

        def webhook_params
          params.permit(:url, :active, events: [])
        end
    end
  end
end
