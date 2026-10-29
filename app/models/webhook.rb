class Webhook < ApplicationRecord
  EVENTS = %w[
    task.created task.updated task.completed task.discarded task.restored
    comment.created
    project.updated project.discarded project.restored
  ].freeze

  belongs_to :project
  has_many :deliveries, class_name: "WebhookDelivery", dependent: :destroy

  # The secret signs payloads, so it must be recoverable: encrypted, not hashed.
  encrypts :secret

  before_validation :generate_secret, on: :create

  validates :url, presence: true, length: { maximum: 2_000 }
  validate :url_is_acceptable
  validate :events_are_known

  scope :active, -> { where(active: true) }
  # An empty +events+ list subscribes to everything.
  scope :listening_to, ->(event) { where("events = '{}' OR ? = ANY(events)", event) }

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
