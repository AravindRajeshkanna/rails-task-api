module Ai
  # Explainable ranking, no text generation: who finished similar tasks before (embedding similarity)
  # weighed against who is already swamped. Cheaper and easier to audit than asking a model to pick.
  class SuggestAssignee
    EXPERTISE_WEIGHT = 3.0
    OPEN_TASK_PENALTY = 0.25
    OVERDUE_PENALTY = 0.5
    SIMILAR_POOL = 20

    Candidate = Struct.new(:user_id, :name, :score, :reasons, keyword_init: true)

    def initialize(user:, project:)
      @user = user
      @project = project
    end

    def call(title:, description: nil, task: nil, limit: 3)
      runner = Runner.new(user: @user, project: @project)
      similar = SimilarTasks.new(project: @project, runner: runner)
        .find(text: "#{title}\n#{description}", task: task, limit: SIMILAR_POOL, done_only: true)

      expertise = similar.select(&:assignee_id).group_by(&:assignee_id).transform_values { |tasks|
        [ tasks.size, tasks.sum { |neighbor| 1 - neighbor.neighbor_distance } ]
      }
      open_counts = @project.tasks.kept.where.not(status: :done).group(:assignee_id).count
      overdue_counts = @project.tasks.kept.overdue.group(:assignee_id).count

      candidates = @project.memberships.includes(:user).map { |membership|
        member = membership.user
        finished, weight = expertise.fetch(member.id, [ 0, 0.0 ])
        open = open_counts.fetch(member.id, 0)
        overdue = overdue_counts.fetch(member.id, 0)

        Candidate.new(
          user_id: member.id, name: member.name,
          score: (EXPERTISE_WEIGHT * weight - OPEN_TASK_PENALTY * open - OVERDUE_PENALTY * overdue).round(2),
          reasons: reasons(finished, open, overdue)
        )
      }

      candidates.sort_by { |candidate| [ -candidate.score, candidate.user_id ] }.first(limit)
    end

    private
      def reasons(finished, open, overdue)
        [].tap do |list|
          list << "finished #{finished} similar #{'task'.pluralize(finished)}" if finished.positive?
          list << "#{open} open #{'task'.pluralize(open)}"
          list << "#{overdue} overdue" if overdue.positive?
          list << "no comparable past tasks yet" if finished.zero?
        end
      end
  end
end
