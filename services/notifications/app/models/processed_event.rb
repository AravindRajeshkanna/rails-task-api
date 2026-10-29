class ProcessedEvent < ApplicationRecord
  RETENTION = 14.days # longer than the queue retention, so a redelivered event is still recognised

  def self.prune! = where(created_at: ...RETENTION.ago).delete_all
end
