module Api
  module V1
    # GET /search?q=...: full-text search across every project the caller can see, best match first.
    # (Searching inside one project is `?search=` on its task list.) Archived projects and deleted tasks
    # never match. Optional: project_id.
    class SearchController < BaseController
      def index
        authorize Project, :index?
        query = TaskSearch.new(policy_scope(Task), params.require(:q), project_id: params[:project_id])
        records, meta = paginate(query.call.includes(:project))
        render_resource SearchResultResource, records, meta: meta
      end
    end
  end
end
