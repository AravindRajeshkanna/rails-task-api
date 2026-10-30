module Api
  module V1
    # /organizations/:organization_id/members. Who may do what is in OrganizationMembershipPolicy.
    # People join by invitation (OrganizationInvitationsController), not by being added.
    class OrganizationMembershipsController < BaseController
      before_action :set_organization
      before_action :set_membership, only: %i[update destroy]

      def index
        authorize @organization.organization_memberships.build, :index?
        members = policy_scope(@organization.organization_memberships).includes(:user).order(:created_at, :id)
        records, meta = paginate(members)
        render_resource OrganizationMemberResource, records, meta: meta
      end

      def update
        authorize @membership
        @organization.with_lock { @membership.update!(role: params.require(:role)) } # see Organizations::RemoveMember
        render_resource OrganizationMemberResource, @membership
      end

      # Also how a member leaves. Takes the person's access to the organization's projects with them.
      def destroy
        authorize @membership
        Organizations::RemoveMember.call(membership: @membership)
        head :no_content
      end

      private
        def set_organization
          @organization = policy_scope(Organization).find(params[:organization_id])
        end

        def set_membership
          @membership = policy_scope(@organization.organization_memberships).find(params[:id])
        end
    end
  end
end
