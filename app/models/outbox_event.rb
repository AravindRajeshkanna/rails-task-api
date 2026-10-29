# An event waiting to be published to the other services, or already published (kept for a week so
# a surprise can be traced). See Events::Outbox for writing one and Events::OutboxRelay for sending them.
class OutboxEvent < ApplicationRecord
  RETRY_CAP = 15.minutes

  scope :pending, -> { where(published_at: nil) }
  scope :published, -> { where.not(published_at: nil) }

  # Up to +limit+ pending events that are due and not leased by another relay, oldest first, now leased
  # to the caller for +lease+. Two relays running at once get different rows (FOR UPDATE SKIP LOCKED); a
  # relay that dies mid-batch loses its lease and the rows are claimed again, which is why delivery is
  # at-least-once and consumers deduplicate on the event id.
  def self.claim(limit:, lease:)
    now = Time.current
    transaction do
      ids = pending.where("available_at <= ?", now).where("locked_until IS NULL OR locked_until < ?", now)
                   .order(:id).limit(limit).lock("FOR UPDATE SKIP LOCKED").pluck(:id)
      where(id: ids).update_all([ "locked_until = ?, attempts = attempts + 1", now + lease ]) # rubocop:disable Rails/SkipsModelValidations -- a lease, not an edit
      where(id: ids).order(:id).to_a
    end
  end

  def mark_published!
    update!(published_at: Time.current, locked_until: nil, last_error: nil)
  end

  # Back off exponentially (2, 4, 8, ... seconds, capped), so a long outage is probed gently.
  def mark_failed!(error)
    update!(
      available_at: [ 2**attempts, RETRY_CAP ].min.seconds.from_now, locked_until: nil,
      last_error: "#{error.class}: #{error.message}".truncate(500)
    )
  end
end
