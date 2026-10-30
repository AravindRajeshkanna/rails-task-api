# How one person wants to hear about things, beyond the inbox (which always gets everything that is not muted):
#
#   digest: "off"    an email for each event (when this app sends them: NOTIFICATIONS_MODE=local; otherwise the Notification service does)
#   digest: "daily"  no email per event; one summary of what is new and unread, sent at digest_hour in time_zone (NotificationDigestJob)
#
# One row per person, created the first time they change something; NotificationSetting.for(user) is the row or, until then, the defaults.
class NotificationSetting < ApplicationRecord
  DIGESTS = %w[off daily].freeze
  DIGEST_SPACING = 20.hours # a summary is never sent twice within this, whatever the clock does around a daylight-saving change

  belongs_to :user

  validates :digest, inclusion: { in: DIGESTS }
  validates :digest_hour, numericality: { only_integer: true, in: 0..23 }
  validate :time_zone_exists

  scope :daily, -> { where(digest: "daily") }

  def self.for(user) = find_or_initialize_by(user_id: user.id)

  def daily? = digest == "daily"

  def zone = ActiveSupport::TimeZone[time_zone]

  # True once a day, in the hour the person chose, in their time zone.
  def digest_due?(now = Time.current)
    daily? && zone.at(now).hour == digest_hour && (last_digest_at.nil? || last_digest_at <= now - DIGEST_SPACING)
  end

  private
    def time_zone_exists
      errors.add(:time_zone, "is not a known time zone (use an IANA name such as Europe/Paris)") unless ActiveSupport::TimeZone[time_zone.to_s]
    end
end
