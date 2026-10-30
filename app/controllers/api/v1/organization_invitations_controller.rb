module Api
  module V1
    # /organizations/:organization_id/invitations: owners and admins invite people by email address.
    # See OrganizationInvitationPolicy for who may do what and InvitationAcceptancesController for redeeming one.
    class OrganizationInvitationsController < BaseController
      # Sending mail is not free, and this is the endpoint to mail strangers with.
      rate_limit to: 30, within: 1.hour, only: :create, by: -> { current_user.id },
                 with: -> { render_error :too_many_requests, "rate_limited", "Too many invitations. Try again later." }

      before_action :set_organization

      def index
        authorize @organization.organization_invitations.build, :index?
        invitations = policy_scope(@organization.organization_invitations).pending.includes(:invited_by).order(:created_at, :id)
        records, meta = paginate(invitations)
        render_resource OrganizationInvitationResource, records, meta: meta
      end

      # 201 whether or not the address belongs to a user. The token travels by email only: it is
      # not in the response, or the inviter could redeem it.
      def create
        role = params[:role] || "member"
        authorize @organization.organization_invitations.build(role: role)
        invitation = Organizations::Invite.call(
          organization: @organization, email_address: params.require(:email_address), role: role, invited_by: current_user
        )
        render_resource OrganizationInvitationResource, invitation, status: :created
      end

      def destroy
        invitation = policy_scope(@organization.organization_invitations).pending.find(params[:id])
        authorize invitation
        invitation.revoke!
        head :no_content
      end

      private
        def set_organization
          @organization = policy_scope(Organization).find(params[:organization_id])
        end
    end
  end
end
