module Api
  module V1
    # Change history for a project and everything audited inside it. Admins only.
    class AuditEventsController < BaseController
      def index
        project = policy_scope(Project).kept.find(params[:project_id])
        authorize project, :audit?

        events = project.audit_events.includes(:actor).order(created_at: :desc, id: :desc)
        events = events.where(auditable_type: params[:auditable_type]) if params[:auditable_type].present?
        records, meta = paginate(events)
        render_resource AuditEventResource, records, meta: meta
      end
    end
  end
end
