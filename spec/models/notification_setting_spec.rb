require "rails_helper"

RSpec.describe NotificationSetting do
  it "starts with no digest, in UTC at 8, for someone who never changed anything" do
    setting = described_class.for(create(:user))

    expect(setting).to be_new_record
    expect(setting).to have_attributes(digest: "off", digest_hour: 8, time_zone: "UTC", last_digest_at: nil)
  end

  it "validates the digest, the hour and the zone" do
    expect(build(:notification_setting, digest: "weekly")).not_to be_valid
    expect(build(:notification_setting, digest_hour: 24)).not_to be_valid
    expect(build(:notification_setting, digest_hour: -1)).not_to be_valid
    expect(build(:notification_setting, digest_hour: 1.5)).not_to be_valid
    expect(build(:notification_setting, time_zone: "Mars/Olympus")).not_to be_valid
    expect(build(:notification_setting, :daily, time_zone: "Europe/Paris", digest_hour: 23)).to be_valid
  end

  describe "#digest_due?" do
    let(:paris) { build(:notification_setting, :daily, time_zone: "Europe/Paris", digest_hour: 8) }

    it "is due in the hour they chose, in their own time zone, and at no other hour" do
      expect(paris.digest_due?(Time.utc(2026, 11, 10, 7, 5))).to be(true)  # 08:05 in Paris (UTC+1)
      expect(paris.digest_due?(Time.utc(2026, 11, 10, 8, 5))).to be(false) # 09:05 there
      expect(paris.digest_due?(Time.utc(2026, 11, 10, 6, 59))).to be(false)
    end

    it "follows daylight saving time" do
      expect(paris.digest_due?(Time.utc(2026, 7, 10, 6, 5))).to be(true) # 08:05 in Paris in summer (UTC+2)
    end

    it "is never due when the digest is off" do
      paris.digest = "off"

      expect(paris.digest_due?(Time.utc(2026, 11, 10, 7, 5))).to be(false)
    end

    it "is due once a day: not again within 20 hours of the last one, and again after" do
      now = Time.utc(2026, 11, 10, 7, 5)

      paris.last_digest_at = now - 10.minutes
      expect(paris.digest_due?(now)).to be(false)
      paris.last_digest_at = now - 24.hours
      expect(paris.digest_due?(now)).to be(true)
    end
  end

  it "is one per person" do
    setting = create(:notification_setting)

    expect { described_class.create!(user: setting.user) }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end
