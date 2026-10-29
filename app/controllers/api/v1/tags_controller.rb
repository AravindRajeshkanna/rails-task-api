module Api
  module V1
    class TagsController < BaseController
      before_action :set_project, only: %i[index create]

      def index
        authorize @project, :show?
        tags = policy_scope(@project.tags).order(:name)
        records, meta = paginate(tags)
        render_resource TagResource, records, meta: meta
      end

      def create
        tag = @project.tags.build
        authorize tag
        tag.update!(params.permit(:name))
        render_resource TagResource, tag, status: :created
      end

      def destroy
        tag = policy_scope(Tag).find(params[:id])
        authorize tag
        tag.destroy!
        head :no_content
      end

      private
        def set_project
          @project = policy_scope(Project).kept.find(params[:project_id])
        end
    end
  end
end
