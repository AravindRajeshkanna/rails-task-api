module Api
  module V1
    class ProjectsController < BaseController
      before_action :set_project, only: %i[show update destroy]

      def index
        authorize Project
        projects = policy_scope(Project).kept.includes(:owner).order(created_at: :desc, id: :desc)
        records, meta = paginate(projects)
        render_resource ProjectResource, records, meta: meta
      end

      def show
        authorize @project
        render_resource ProjectDetailResource, @project
      end

      # `organization_id` creates the project inside an organization the caller belongs to (404 otherwise).
      # It is fixed for life, so it is not a permitted attribute of #update.
      def create
        authorize Project
        organization = policy_scope(Organization).find(params[:organization_id]) if params[:organization_id].present?
        authorize organization, :create_project? if organization

        project = current_user.owned_projects.create!(project_params.merge(organization: organization))
        render_resource ProjectDetailResource, policy_scope(Project).find(project.id), status: :created
      end

      def update
        authorize @project
        @project.update!(project_params)
        render_resource ProjectDetailResource, @project
      end

      def destroy
        authorize @project
        @project.discard
        head :no_content
      end

      # POST /projects/:id/restore
      def restore
        project = policy_scope(Project).discarded.find(params[:id])
        authorize project
        project.undiscard
        render_resource ProjectDetailResource, project
      end

      private
        def set_project
          @project = policy_scope(Project).kept.find(params[:id])
        end

        def project_params
          params.permit(:name, :description)
        end
    end
  end
end
