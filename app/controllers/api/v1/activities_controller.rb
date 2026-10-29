module Api
  module V1
    # GET /activity: what happened across every project the caller belongs to, newest first.
    # The audit log (/projects/:id/audit_events) is the admin's view of one project; this is the
    # member's view of all of them. It reads the same events and scopes them through the
    # caller's visible projects, so a project you are not in, or one that is deleted, adds nothing.
    class ActivitiesController < BaseController
      ACTIVITY_TYPES = %w[Project Task Membership].freeze

      def index
        authorize Project, :index?
        projects = policy_scope(Project).kept
        projects = projects.where(id: params[:project_id]) if params[:project_id].present?

        events = AuditEvent.where(project_id: projects.reselect("projects.id"), auditable_type: types)
                           .includes(:actor).order(created_at: :desc, id: :desc)
        records, meta = paginate(events)
        render_resource ActivityResource, records, meta: meta
      end

      private
        def types
          requested = params[:type].to_s.split(",").map(&:strip).compact_blank
          unknown = requested - ACTIVITY_TYPES
          raise InvalidParameterError.new("type", "type must be one or more of: #{ACTIVITY_TYPES.join(', ')}") if unknown.any?

          requested.presence || ACTIVITY_TYPES
        end
    end
  end
end
