module Api
  module V1
    # What the caller has silenced: a kind everywhere, a project entirely, or one kind in one project (see NotificationMute).
    class NotificationMutesController < BaseController
      idempotent :create # a retried POST with the same Idempotency-Key answers the first one's response (Idempotency)
      # GET /notification_mutes
      def index
        authorize NotificationMute
        records, meta = paginate(policy_scope(NotificationMute).order(:id))
        render_resource NotificationMuteResource, records, meta: meta
      end

      # POST /notification_mutes with { kind: "comment.created" }, { project_id: 3 } or both. A project the caller cannot see is a 404.
      def create
        authorize NotificationMute
        project = policy_scope(Project).find(params[:project_id].to_s) if params[:project_id].present?
        mute = current_user.notification_mutes.create!(kind: params[:kind].presence, project: project)
        render_resource NotificationMuteResource, mute, status: :created
      end

      # DELETE /notification_mutes/:id
      def destroy
        mute = policy_scope(NotificationMute).find(params[:id])
        authorize mute
        mute.destroy!
        head :no_content
      end
    end
  end
end
