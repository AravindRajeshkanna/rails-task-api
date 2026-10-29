module Ai
  # Nearest neighbours by embedding, always inside one project (the tenant boundary). Failure to embed
  # degrades to "no similar tasks" rather than failing the request that asked.
  class SimilarTasks
    def initialize(project:, runner:)
      @project = project
      @runner = runner
    end

    # A stored task uses its own vector; anything else is embedded from +text+ on demand.
    def find(text:, task: nil, limit: 5, done_only: false)
      vector = task&.embedding || embed(text)
      return [] if vector.blank?

      scope = @project.tasks.kept.where.not(embedding: nil)
      scope = scope.done if done_only
      scope = scope.where.not(id: task.id) if task&.persisted?
      scope.nearest_neighbors(:embedding, vector, distance: "cosine").limit(limit).select { |neighbor|
        neighbor.neighbor_distance <= Ai.config.similar_task_max_distance
      }
    end

    private
      def embed(text)
        return if text.blank?

        @runner.embed(text, feature: "similar_search").vector
      rescue BudgetExceeded
        raise
      rescue Error => error
        Rails.logger.warn("Ai::SimilarTasks skipped: #{error.message}")
        nil
      end
  end
end
