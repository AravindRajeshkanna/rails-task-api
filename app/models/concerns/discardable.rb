# Soft deletion. Records are hidden by the +kept+ scope instead of being removed,
# and can be restored until PurgeDiscardedJob removes them for good.
module Discardable
  extend ActiveSupport::Concern

  included do
    scope :kept, -> { where(discarded_at: nil) }
    scope :discarded, -> { where.not(discarded_at: nil) }
  end

  def discarded? = discarded_at.present?
  def kept? = !discarded?

  def discard
    kept? ? update(discarded_at: Time.current) : false
  end

  def undiscard
    discarded? ? update(discarded_at: nil) : false
  end
end
