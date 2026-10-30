# Deletes published outbox events after a week. Pending ones are never deleted. Scheduled daily in config/recurring.yml.
class PurgeOutboxJob < ApplicationJob
  RETENTION = 7.days

  queue_as :default

  def perform
    OutboxEvent.published.where(published_at: ..RETENTION.ago).in_batches.delete_all
  end
end
