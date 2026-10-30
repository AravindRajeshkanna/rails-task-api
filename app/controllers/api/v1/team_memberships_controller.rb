module Api
  module V1
    # /organizations/:organization_id/teams/:team_id/members. Who may do what is in TeamMembershipPolicy.
    class TeamMembershipsController < BaseController
      idempotent :create # a retried POST with the same Idempotency-Key answers the first one's response (Idempotency)
      before_action :set_team

      def index
        authorize @team.team_memberships.build, :index?
        members = policy_scope(@team.team_memberships).includes(:user).order(:created_at, :id)
        records, meta = paginate(members)
        render_resource TeamMemberResource, records, meta: meta
      end

      # Adds a member of the organization by user id, as a plain member unless `role: "maintainer"` is given (administrators only).
      # A person who is not in the organization, and an id that matches nobody, get the same 422.
      def create
        membership = @team.team_memberships.build(user: user_in_organization, role: params[:role].presence || "member")
        authorize membership
        if membership.user.nil?
          membership.errors.add(:user, "must be a member of the team's organization")
          raise ActiveRecord::RecordInvalid, membership
        end
        membership.save!
        render_resource TeamMemberResource, membership, status: :created
      end

      # PATCH with { role: "maintainer" | "member" }: administrators only.
      def update
        membership = policy_scope(@team.team_memberships).find(params[:id])
        authorize membership
        membership.update!(role: params.require(:role))
        render_resource TeamMemberResource, membership
      end

      def destroy
        membership = policy_scope(@team.team_memberships).find(params[:id])
        authorize membership
        membership.destroy!
        head :no_content
      end

      private
        def set_team
          organization = policy_scope(Organization).find(params[:organization_id])
          @team = policy_scope(organization.teams).find(params[:team_id])
        end

        # The user with this id if they are in the team's organization, otherwise nil.
        def user_in_organization
          User.where(id: @team.organization.organization_memberships.select(:user_id)).find_by(id: params.require(:user_id))
        end
    end
  end
end
