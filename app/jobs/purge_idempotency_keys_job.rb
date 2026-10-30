# Deletes idempotency keys older than their retention (a client that retries after a day is not retrying, it is repeating itself).
class PurgeIdempotencyKeysJob < ApplicationJob
  queue_as :low

  def perform
    IdempotencyKey.expired.in_batches(of: 5_000).delete_all
  end
end
