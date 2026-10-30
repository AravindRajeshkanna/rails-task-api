module Api
  module V1
    # The organization's history: renames, who joined or left, role changes, invitations sent and answered,
    # teams and who is in them, and the projects teams were granted.
    # Owners only (an invitation's changes carry the invited email address).
    class OrganizationAuditEventsController < BaseController
      AUDITED_TYPES = %w[Organization OrganizationMembership OrganizationInvitation Team TeamMembership ProjectTeam].freeze

      def index
        organization = policy_scope(Organization).find(params[:organization_id])
        authorize organization, :audit?

        events = organization.audit_events.includes(:actor).order(created_at: :desc, id: :desc)
        if params[:auditable_type].present?
          raise InvalidParameterError.new("auditable_type", "auditable_type must be one of: #{AUDITED_TYPES.join(', ')}") unless AUDITED_TYPES.include?(params[:auditable_type])

          events = events.where(auditable_type: params[:auditable_type])
        end
        records, meta = params.key?(:cursor) ? paginate_by_cursor(events, params[:cursor]) : paginate(events)
        render_resource AuditEventResource, records, meta: meta
      end
    end
  end
end
