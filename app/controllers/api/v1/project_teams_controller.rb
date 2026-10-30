module Api
  module V1
    # /projects/:project_id/teams: which teams of the project's organization have access, and as what.
    # Who may do what is in ProjectTeamPolicy.
    class ProjectTeamsController < BaseController
      idempotent :create # a retried POST with the same Idempotency-Key answers the first one's response (Idempotency)
      before_action :set_project
      before_action :set_project_team, only: %i[update destroy]

      def index
        authorize @project.project_teams.build, :index?
        grants = policy_scope(@project.project_teams).includes(:team).order(:created_at, :id)
        records, meta = paginate(grants)
        render_resource ProjectTeamResource, records, meta: meta
      end

      # Grants a team of the project's organization access. A team from anywhere else, and an id that
      # matches no team, get the same 422.
      def create
        project_team = @project.project_teams.build(team: team_of_organization, role: params[:role] || "member")
        authorize project_team
        if project_team.team.nil?
          project_team.errors.add(:team, "must belong to the project's organization")
          raise ActiveRecord::RecordInvalid, project_team
        end
        project_team.save!
        render_resource ProjectTeamResource, project_team, status: :created
      end

      def update
        authorize @project_team
        @project_team.update!(role: params.require(:role))
        render_resource ProjectTeamResource, @project_team
      end

      def destroy
        authorize @project_team
        @project_team.destroy!
        head :no_content
      end

      private
        def set_project
          @project = policy_scope(Project).kept.find(params[:project_id])
        end

        def set_project_team
          @project_team = policy_scope(@project.project_teams).find(params[:id])
        end

        def team_of_organization
          return unless @project.organization_id

          Team.where(organization_id: @project.organization_id).find_by(id: params.require(:team_id))
        end
    end
  end
end
