# One remembered request. See the Idempotency concern for the protocol; this is only the storage and the arithmetic on it.
class IdempotencyKey < ApplicationRecord
  MAX_KEY_LENGTH = 255
  KEY_FORMAT = /\A[\x21-\x7E]+\z/ # visible ASCII, no spaces: what an opaque token or a UUID looks like
  RETENTION = 24.hours
  TAKEOVER_AFTER = 1.minute # a request still "in progress" after this crashed or was killed

  belongs_to :user

  scope :expired, -> { where(created_at: ...RETENTION.ago) }

  def self.valid_key?(key) = key.is_a?(String) && key.length <= MAX_KEY_LENGTH && KEY_FORMAT.match?(key)

  # Claims (user, key) for a request. Answers :claimed (run it), :replay (the stored response is current), :in_progress (another request holds
  # it), :mismatch (the key was used for a different request) or :taken_over (a stale claim was taken: run it). The unique index decides races.
  def self.claim(user_id:, key:, fingerprint:)
    now = Time.current
    inserted = insert({ user_id: user_id, key: key, request_fingerprint: fingerprint, locked_at: now, created_at: now }, unique_by: %i[user_id key]) # rubocop:disable Rails/SkipsModelValidations -- ON CONFLICT DO NOTHING is the point
    return [ :claimed, find_by!(user_id: user_id, key: key) ] if inserted.rows.any?

    existing = find_by(user_id: user_id, key: key)
    return claim(user_id: user_id, key: key, fingerprint: fingerprint) if existing.nil? # purged between the insert and the read: try again
    if existing.created_at < RETENTION.ago
      existing.destroy # a key older than its retention is a new key
      return claim(user_id: user_id, key: key, fingerprint: fingerprint)
    end
    return [ :mismatch, existing ] unless ActiveSupport::SecurityUtils.secure_compare(existing.request_fingerprint, fingerprint)
    return [ :replay, existing ] if existing.completed?
    return [ :in_progress, existing ] if existing.locked_at > TAKEOVER_AFTER.ago

    # Stale: take it over, but only if nobody else just did.
    taken = where(id: existing.id, locked_at: existing.locked_at).update_all(locked_at: now) # rubocop:disable Rails/SkipsModelValidations
    taken == 1 ? [ :taken_over, existing ] : [ :in_progress, existing ]
  end

  def completed? = response_status.present?

  def complete!(status:, body:)
    update!(response_status: status, response_body: body)
  end
end
