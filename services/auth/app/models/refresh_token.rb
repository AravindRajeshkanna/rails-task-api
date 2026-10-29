# A long-lived, single-use credential that exchanges for a new access token. Only a digest is stored.
#
# Every use rotates it: the old token is revoked and a new one issued in the same family. Using a
# revoked token again means it leaked (a thief and the owner both hold it), so the whole family is
# revoked and both are signed out. See RefreshToken.rotate!.
class RefreshToken < ApplicationRecord
  class Invalid < StandardError; end
  class Reused < StandardError; end

  belongs_to :user

  scope :active, -> { where(revoked_at: nil).where(expires_at: Time.current..) }

  # Returns [record, plaintext token]; the plaintext cannot be recovered later.
  def self.issue!(user, family_id: SecureRandom.uuid, ip_address: nil, user_agent: nil)
    token = SecureRandom.base58(48)
    record = user.refresh_tokens.create!(
      token_digest: digest(token), family_id: family_id, expires_at: Rails.configuration.x.auth.refresh_ttl.from_now,
      ip_address: ip_address, user_agent: user_agent&.truncate(255)
    )
    [ record, token ]
  end

  def self.rotate!(token, ip_address: nil, user_agent: nil)
    outcome = transaction do
      record = lock.find_by(token_digest: digest(token.to_s))
      next :invalid unless record

      if record.revoked_at
        revoke_family!(record.family_id)
        next :reused
      end
      next :invalid if record.expires_at <= Time.current

      record.update!(revoked_at: Time.current)
      issue!(record.user, family_id: record.family_id, ip_address: ip_address, user_agent: user_agent)
    end

    raise Reused if outcome == :reused
    raise Invalid if outcome == :invalid

    outcome
  end

  def self.revoke_family!(family_id)
    where(family_id: family_id, revoked_at: nil).update_all(revoked_at: Time.current) # rubocop:disable Rails/SkipsModelValidations -- one UPDATE for the whole family
  end

  # Signing out: revokes the token's whole family. Unknown tokens are ignored, so it is safe to repeat.
  def self.revoke!(token)
    record = find_by(token_digest: digest(token.to_s))
    revoke_family!(record.family_id) if record
  end

  def self.digest(token) = OpenSSL::Digest::SHA256.hexdigest(token)
end
