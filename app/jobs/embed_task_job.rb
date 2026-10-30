# Embeds a task's text for similarity search. Runs off the request path on Solid Queue, so a slow or
# throttled model provider never slows a task save.
class EmbedTaskJob < ApplicationJob
  queue_as :low

  retry_on Ai::Unavailable, wait: :polynomially_longer, attempts: 6
  # Nothing to retry now: AI is off, or today's budget is gone (the backfill task picks the task up later).
  discard_on Ai::Disabled, Ai::BudgetExceeded, Ai::InvalidResponse

  def perform(task)
    return if task.discarded?

    Ai::Embedder.call(task)
  end
end
