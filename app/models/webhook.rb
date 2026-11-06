class Webhook < ApplicationRecord
  EVENTS = %w[
    task.created task.updated task.completed task.discarded task.restored
    comment.created
    project.updated project.discarded project.restored
  ].freeze

  belongs_to :project
  has_many :deliveries, class_name: "WebhookDelivery", dependent: :destroy

  # The secret signs payloads, so it must be recoverable: encrypted, not hashed. The key is KMS's (ADR 69). Secrets written before that were encrypted with the
  # Rails credentials key and still read; `bin/rails kms:encrypt` re-encrypts them.
  encrypts_with_kms :secret, legacy_credentials: true
  # The secret being rotated in (ADR 78): encrypted like the one it will replace, and never under the credentials key, which it has no history with.
  encrypts_with_kms :next_secret

  before_validation :generate_secret, on: :create

  validates :url, presence: true, length: { maximum: 2_000 }
  validate :url_is_acceptable
  validate :events_are_known

  scope :active, -> { where(active: true) }
  # An empty +events+ list subscribes to everything.
  scope :listening_to, ->(event) { where("events = '{}' OR ? = ANY(events)", event) }

  # Replacing the signing secret without a moment when the receiver rejects the events (ADR 78). Three steps, each the owner's:
  #
  #   begin_secret_rotation!   makes a new secret and returns it, once. Every delivery is now signed with both: X-TaskApi-Signature with the current secret,
  #                            as before, so a receiver that has done nothing keeps working, and X-TaskApi-Signature-Next with the new one.
  #   promote_next_secret      the new secret becomes the current one and the old one is gone. Deliveries carry one signature again.
  #   cancel_secret_rotation   forgets the new secret. The current one never changed.
  #
  # Starting again while one is under way replaces the new secret (it never signed alone, so no receiver depends on it): that is also how a new secret that
  # was lost, since it is shown once, is made again.
  def rotating? = rotation_started_at.present?

  def begin_secret_rotation!
    update!(next_secret: SecureRandom.hex(32), rotation_started_at: Time.current)
    next_secret
  end

  # False when no rotation is under way (two admins pressing the button, a retry): the lock makes the second one find the first one's work.
  def promote_next_secret
    with_lock do
      next false unless rotating?

      update!(secret: next_secret, next_secret: nil, rotation_started_at: nil)
    end
  end

  def cancel_secret_rotation
    with_lock do
      next false unless rotating?

      update!(next_secret: nil, rotation_started_at: nil)
    end
  end

  private
    def generate_secret
      self.secret ||= SecureRandom.hex(32)
    end

    def url_is_acceptable
      uri = URI.parse(url.to_s)
      allowed = Rails.env.production? ? [ URI::HTTPS ] : [ URI::HTTPS, URI::HTTP ]
      unless allowed.any? { |scheme| uri.is_a?(scheme) } && uri.host.present?
        errors.add(:url, Rails.env.production? ? "must be an https URL" : "must be an http(s) URL")
      end
    rescue URI::InvalidURIError
      errors.add(:url, "is not a valid URL")
    end

    def events_are_known
      unknown = events - EVENTS
      errors.add(:events, "contains unknown events: #{unknown.join(', ')}") if unknown.any?
    end
end
