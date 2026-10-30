module Api
  module V1
    # Change history for a project and everything audited inside it. Admins only.
    class AuditEventsController < BaseController
      replica_reads :index # a moment of staleness is fine here (ReplicaRouting)
      def index
        project = policy_scope(Project).kept.find(params[:project_id])
        authorize project, :audit?

        events = project.audit_events.includes(:actor).order(created_at: :desc, id: :desc)
        events = events.where(auditable_type: params[:auditable_type]) if params[:auditable_type].present?
        # ?cursor= (even empty) pages by keyset: constant cost however long the history, no total. Otherwise ?page=.
        records, meta = params.key?(:cursor) ? paginate_by_cursor(events, params[:cursor]) : paginate(events)
        render_resource AuditEventResource, records, meta: meta
      end
    end
  end
end
