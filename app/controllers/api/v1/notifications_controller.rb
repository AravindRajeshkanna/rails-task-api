module Api
  module V1
    # The caller's inbox. Who may see what is in NotificationPolicy.
    class NotificationsController < BaseController
      # GET /notifications?unread=true&project_id=3&kind=task.assigned (newest first).
      # meta.unread_count is the number of unread notifications, whatever the filter.
      def index
        authorize Notification
        scope = policy_scope(Notification)
        records, meta = paginate(filtered(scope).includes(:actor).newest_first)
        render_resource NotificationResource, records, meta: meta.merge(unread_count: scope.unread.count)
      end

      # PATCH /notifications/:id with { "read": true } (or false, to mark it unread again). Idempotent.
      def update
        notification = policy_scope(Notification).find(params[:id])
        authorize notification
        notification.mark_read!(read: ActiveModel::Type::Boolean.new.cast(params.require(:read)))
        render_resource NotificationResource, notification
      end

      def destroy
        notification = policy_scope(Notification).find(params[:id])
        authorize notification
        notification.destroy!
        head :no_content
      end

      # POST /notifications/read_all, optionally for one project. Answers how many it marked.
      def read_all
        authorize Notification
        scope = policy_scope(Notification).unread
        scope = scope.where(project_id: params[:project_id]) if params[:project_id].present?
        updated = scope.update_all(read_at: Time.current) # rubocop:disable Rails/SkipsModelValidations -- a bulk state flip, no callbacks wanted
        render json: { data: { updated: updated } }
      end

      private
        def filtered(scope)
          scope = scope.unread if ActiveModel::Type::Boolean.new.cast(params[:unread])
          scope = scope.where(project_id: params[:project_id]) if params[:project_id].present?
          scope = scope.where(kind: kinds) if params[:kind].present?
          scope
        end

        def kinds
          requested = params[:kind].to_s.split(",").map(&:strip).compact_blank
          unknown = requested - Notification::KINDS
          raise InvalidParameterError.new("kind", "kind must be one or more of: #{Notification::KINDS.join(', ')}") if unknown.any?

          requested
        end
    end
  end
end
