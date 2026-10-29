module Api
  module V1
    # /organizations/:organization_id/members. Who may do what is in OrganizationMembershipPolicy.
    class OrganizationMembershipsController < BaseController
      before_action :set_organization
      before_action :set_membership, only: %i[update destroy]

      def index
        authorize @organization.organization_memberships.build, :index?
        members = policy_scope(@organization.organization_memberships).includes(:user).order(:created_at, :id)
        records, meta = paginate(members)
        render_resource OrganizationMemberResource, records, meta: meta
      end

      # Adds an existing user by email address.
      def create
        authorize @organization.organization_memberships.build(role: params[:role] || "member")
        membership = Organizations::AddMember.call(
          organization: @organization, email_address: params.require(:email_address), role: params[:role] || "member"
        )
        render_resource OrganizationMemberResource, membership, status: :created
      end

      def update
        authorize @membership
        @membership.update!(role: params.require(:role))
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
