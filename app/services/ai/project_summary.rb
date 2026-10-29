module Ai
  # A status report for a project. Cached per project version (tasks touch their project, so any
  # change invalidates it) and for a few minutes at most, so repeated reads cost nothing.
  class ProjectSummary
    RECENT = 14.days
    LIST_SIZE = 10

    def initialize(user:, project:, timezone: "UTC")
      @user = user
      @project = project
      @timezone = timezone
    end

    # Returns the summary hash; :usage is present only when the model was actually called.
    def call(refresh: false)
      key = [ "ai", "project_summary", @project.cache_key_with_version ]
      if !refresh && (cached = Rails.cache.read(key))
        return cached.merge(cached: true)
      end

      result = Runner.new(user: @user, project: @project).run("summarize_project", input)
      summary = result.output.merge(stats: @project.stats, generated_at: Time.current.iso8601)
      Rails.cache.write(key, summary, expires_in: Ai.config.summary_ttl)
      summary.merge(cached: false, usage: result.usage.to_h)
    end

    private
      def input
        open = @project.tasks.kept.where.not(status: :done)
        {
          project: { name: @project.name, description: Context.clip(@project.description, 500) },
          today: Context.today(@timezone).iso8601,
          stats: @project.stats,
          completed_recently: @project.tasks.kept.done.where(completed_at: RECENT.ago..).order(completed_at: :desc).limit(LIST_SIZE)
            .map { |task| { title: Context.clip(task.title, 120), completed_on: task.completed_at.to_date.iso8601 } },
          in_progress: @project.tasks.kept.in_progress.includes(:assignee).order(:due_on).limit(LIST_SIZE).map { |task| line(task) },
          overdue: @project.tasks.kept.overdue.includes(:assignee).order(:due_on).limit(LIST_SIZE).map { |task| line(task) },
          unassigned: open.where(assignee_id: nil).count
        }
      end

      def line(task) = { title: Context.clip(task.title, 120), assignee: task.assignee&.name, due_on: task.due_on&.iso8601 }
  end
end
