module Api
  module V1
    # GET /projects/:project_id/summary[?refresh=true&timezone=Europe/Berlin]
    class ProjectSummariesController < BaseController
      rate_limit to: Ai.config.requests_per_minute, within: 1.minute, by: -> { current_user.id },
        with: -> { render_error :too_many_requests, "rate_limited", "Too many AI requests. Slow down." }

      def show
        project = policy_scope(Project).kept.find(params[:project_id])
        authorize project, :show?

        summary = Ai::ProjectSummary.new(user: current_user, project: project, timezone: params[:timezone].presence || "UTC")
          .call(refresh: ActiveModel::Type::Boolean.new.cast(params[:refresh]))
        render json: { data: summary.except(:usage, :cached), meta: summary.slice(:usage, :cached) }
      end
    end
  end
end
