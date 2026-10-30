module Api
  module V1
    # GET /projects/:project_id/analytics: the numbers behind a project dashboard.
    class AnalyticsController < BaseController
      replica_reads :show # a moment of staleness is fine here (ReplicaRouting)
      # The report is the same for every member and cheap to keep: any change to a task touches
      # its project, which changes the key; the date is in it because "overdue" moves at midnight.
      CACHE_TTL = 5.minutes

      def show
        project = policy_scope(Project).kept.find(params[:project_id])
        authorize project, :analytics?
        form = Analytics::ReportForm.from_params(params).tap(&:validate!)

        report = Rails.cache.fetch([ project.cache_key_with_version, "analytics", form.cache_key, Date.current ], expires_in: CACHE_TTL) do
          Analytics::ProjectReport.new(project, form).call
        end
        render json: { data: report }
      end
    end
  end
end
