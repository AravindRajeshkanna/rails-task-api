# An API login. The bearer token is returned to the client exactly once; only
# its SHA-256 digest is persisted, so a database leak does not leak usable tokens.
# Tokens are 32 random base58 characters (~190 bits), so an unsalted fast hash is safe.
class Session < ApplicationRecord
  TTL = 30.days
  LAST_USED_RESOLUTION = 5.minutes

  belongs_to :user

  scope :active, -> { where(expires_at: Time.current..) }
  scope :expired, -> { where(expires_at: ...Time.current) }

  # Returns [session, plaintext_token].
  def self.start_for!(user, ip_address: nil, user_agent: nil)
    token = SecureRandom.base58(32)
    session = user.sessions.create!(
      token_digest: digest(token),
      ip_address: ip_address,
      user_agent: user_agent&.truncate(255),
      last_used_at: Time.current,
      expires_at: TTL.from_now
    )
    [ session, token ]
  end

  def self.authenticate(token)
    return if token.blank?

    session = active.find_by(token_digest: digest(token))
    session&.tap(&:record_usage)
  end

  def self.digest(token)
    OpenSSL::Digest::SHA256.hexdigest(token.to_s)
  end

  # Coarse-grained so authenticated reads don't turn into writes.
  def record_usage
    return if last_used_at && last_used_at > LAST_USED_RESOLUTION.ago

    # In a savepoint, so a refused write cannot abort a transaction the caller is in.
    transaction(requires_new: true) do
      update_column(:last_used_at, Time.current) # rubocop:disable Rails/SkipsModelValidations -- bookkeeping, no callbacks wanted
    end
  rescue ActiveRecord::StatementInvalid, ActiveRecord::ReadOnlyError => error
    raise unless ReadOnlyMode.error?(error) # a read-only database must not make signed-in reads fail over a timestamp
  end
end
