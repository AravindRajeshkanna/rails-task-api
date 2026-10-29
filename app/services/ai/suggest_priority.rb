module Ai
  # Priority and a completion estimate. The model sees hard evidence: how long similar finished tasks
  # actually took (found by embedding similarity) and the current workload. Dates are computed here,
  # never by the model.
  class SuggestPriority
    Suggestion = Struct.new(:priority, :rationale, :estimated_days, :predicted_due_on, :at_risk, :confidence, :similar_tasks, :usage, keyword_init: true)

    def initialize(user:, project:, timezone: "UTC")
      @user = user
      @project = project
      @timezone = timezone
    end

    def call(task: nil, title: nil, description: nil, due_on: nil)
      today = Context.today(@timezone)
      subject = task ? Context.task(task) : { title: Context.clip(title, 200), description: Context.clip(description, 1_000), due_on: due_on.presence, status: "todo" }
      runner = Runner.new(user: @user, project: @project)

      similar = SimilarTasks.new(project: @project, runner: runner)
        .find(text: "#{subject[:title]}\n#{subject[:description]}", task: task, limit: 5, done_only: true)
      history = similar.map { |neighbor| { title: Context.clip(neighbor.title, 120), priority: neighbor.priority, days_to_complete: days_to_complete(neighbor) } }

      result = runner.run("suggest_priority", { task: subject, today: today.iso8601, signals: signals(task, history) })
      build(result, subject, similar, history, today)
    end

    private
      def signals(task, history)
        days = history.map { |entry| entry[:days_to_complete] }
        {
          similar: history,
          baseline_days: (median(days) if days.size >= 3),
          project_open_tasks: @project.tasks.kept.where.not(status: :done).count,
          assignee_open_tasks: (@project.tasks.kept.where.not(status: :done).where(assignee_id: task.assignee_id).count if task&.assignee_id)
        }.compact
      end

      def build(result, subject, similar, history, today)
        output = result.output
        predicted = (today + output[:estimated_days]) if output[:estimated_days]
        due_on = (Date.iso8601(subject[:due_on].to_s) rescue nil)

        Suggestion.new(
          output.slice(:priority, :rationale, :estimated_days, :confidence).merge(
            predicted_due_on: predicted&.iso8601,
            at_risk: due_on && predicted ? predicted > due_on : nil,
            similar_tasks: similar.zip(history).map { |neighbor, entry| entry.merge(id: neighbor.id) },
            usage: result.usage
          )
        )
      end

      def days_to_complete(task) = [ (task.completed_at.to_date - task.created_at.to_date).to_i, 0 ].max

      def median(values)
        sorted = values.sort
        middle = sorted.size / 2
        sorted.size.odd? ? sorted[middle] : ((sorted[middle - 1] + sorted[middle]) / 2.0).round
      end
  end
end
