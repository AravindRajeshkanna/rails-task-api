# Permanently deletes soft-deleted tasks and projects once they are older than
# the retention window (config.x.discard_retention, 30 days).
#
# Uses Rails 8.1 Active Job Continuations: each `step` is checkpointed and the
# cursor records the last id handled, so if the worker is stopped mid-run (a
# deploy, say) the job resumes where it left off instead of starting over.
class PurgeDiscardedJob < ApplicationJob
  include ActiveJob::Continuable

  queue_as :low

  def perform
    @cutoff = Rails.configuration.x.discard_retention.ago

    step :tasks do |step|
      Task.discarded.where(discarded_at: ..@cutoff).find_each(start: step.cursor) do |task|
        task.destroy!
        step.advance! from: task.id
      end
    end

    step :projects do |step|
      Project.discarded.where(discarded_at: ..@cutoff).find_each(start: step.cursor) do |project|
        project.destroy!
        step.advance! from: project.id
      end
    end
  end
end
