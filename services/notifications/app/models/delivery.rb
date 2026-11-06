class Delivery < ApplicationRecord
  CHANNELS = %w[email slack].freeze
  # The log is evidence that something was sent, not an archive; it holds the recipient's address, so it does not outlive its usefulness. A person who asks to
  # be forgotten is deleted sooner, by recipient_id (Handlers::UserErased, ADR 79); rows from before that column existed have none, and wait for this.
  RETENTION = 90.days

  validates :channel, inclusion: { in: CHANNELS }

  def self.prune! = where(created_at: ...RETENTION.ago).in_batches.delete_all
end
