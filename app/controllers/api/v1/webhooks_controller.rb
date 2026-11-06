module Api
  module V1
    # Project admins register URLs that receive signed JSON events (see Webhooks::Deliverer).
    class WebhooksController < BaseController
      idempotent :create, redact: :secret # a retried POST with the same Idempotency-Key answers the first one's response, without the secret (Idempotency)
      before_action :set_project, only: %i[index create]
      before_action :set_webhook, only: %i[show update destroy rotate_secret promote_secret cancel_rotation]
      # Every rotation encrypts a new secret, which is a request to KMS; a budget of the kind a token rotation has (SessionsController).
      rate_limit to: 20, within: 1.hour, only: :rotate_secret, by: -> { Current.user.id }, with: -> { render_error :too_many_requests, "rate_limited", "Too many rotations. Try again later." }

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

      # POST /webhooks/:id/rotate_secret: a new signing secret, returned here once. From now on every delivery is signed with it as well as with the current
      # one (X-TaskApi-Signature-Next), until it is promoted or cancelled. Not idempotent on purpose: asking twice makes a second new secret, and only the
      # one in the last answer counts, so a retry after a lost answer needs no key and no stored copy of the secret (ADR 78).
      def rotate_secret
        authorize @webhook
        @webhook.begin_secret_rotation!
        Rails.event.notify("webhook.secret_rotation_started", webhook_id: @webhook.id, project_id: @webhook.project_id, actor_id: current_user.id)
        render_resource WebhookWithNextSecretResource, @webhook
      end

      # POST /webhooks/:id/promote_secret: the new secret becomes the secret and the old one stops signing. Do it once the receiver accepts the new one.
      def promote_secret
        authorize @webhook
        return render_no_rotation unless @webhook.promote_next_secret

        Rails.event.notify("webhook.secret_rotation_promoted", webhook_id: @webhook.id, project_id: @webhook.project_id, actor_id: current_user.id)
        render_resource WebhookResource, @webhook
      end

      # POST /webhooks/:id/cancel_rotation: forgets the new secret. The current one is as it was.
      def cancel_rotation
        authorize @webhook
        return render_no_rotation unless @webhook.cancel_secret_rotation

        Rails.event.notify("webhook.secret_rotation_cancelled", webhook_id: @webhook.id, project_id: @webhook.project_id, actor_id: current_user.id)
        render_resource WebhookResource, @webhook
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

        def render_no_rotation
          render_error :conflict, "no_rotation_in_progress", "This webhook has no secret being rotated in. Start one with POST /webhooks/:id/rotate_secret."
        end
    end
  end
end
