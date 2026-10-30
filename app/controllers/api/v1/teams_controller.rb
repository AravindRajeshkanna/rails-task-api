module Api
  module V1
    # /organizations/:organization_id/teams. Who may do what is in TeamPolicy.
    class TeamsController < BaseController
      before_action :set_organization
      before_action :set_team, only: %i[show update destroy]

      def index
        authorize @organization.teams.build, :index?
        records, meta = paginate(with_member_counts(policy_scope(@organization.teams)).order(:name, :id))
        render_resource TeamResource, records, meta: meta
      end

      def show
        authorize @team
        render_resource TeamResource, @team
      end

      def create
        team = @organization.teams.build(team_params)
        authorize team
        team.save!
        render_resource TeamResource, with_member_counts(Team).find(team.id), status: :created
      end

      def update
        authorize @team
        @team.update!(team_params)
        render_resource TeamResource, with_member_counts(Team).find(@team.id)
      end

      # Takes the team's access to projects with it.
      def destroy
        authorize @team
        @team.destroy!
        head :no_content
      end

      private
        def set_organization
          @organization = policy_scope(Organization).find(params[:organization_id])
        end

        def set_team
          @team = with_member_counts(policy_scope(@organization.teams)).find(params[:id])
        end

        def with_member_counts(scope)
          scope.select("teams.*", "(SELECT COUNT(*) FROM team_memberships WHERE team_memberships.team_id = teams.id) AS members_count")
        end

        def team_params = params.permit(:name, :parent_id)
    end
  end
end
