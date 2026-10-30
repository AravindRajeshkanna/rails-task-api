require "rails_helper"

RSpec.describe NotificationDigestJob do
  let(:owner) { create(:user) }
  let(:ada) { create(:user, name: "Ada", email_address: "ada@example.com") }
  let!(:project) { create(:project, owner: owner, name: "Apollo") }
  let(:task) { create(:task, project: project, creator: owner, assignee: ada, title: "Land on the moon") }
  let(:morning) { Time.utc(2026, 11, 10, 8, 5) } # 08:05 UTC

  before do
    create(:membership, project: project, user: ada)
    create(:notification, user: ada, project: project, task: task, created_at: morning - 3.hours)
  end

  def digest_for(user, **attributes) = create(:notification_setting, :daily, user: user, **attributes)

  it "emails the unread summary once, in the hour they chose, and notes when it was sent" do
    setting = digest_for(ada)

    expect { described_class.perform_now(morning) }.to have_enqueued_mail(NotificationDigestMailer, :daily).once

    expect(setting.reload.last_digest_at).to eq(morning)
    expect { described_class.perform_now(morning + 10.minutes) }.not_to have_enqueued_mail(NotificationDigestMailer, :daily)
  end

  it "sends in the hour they chose in their own time zone, not in UTC" do
    digest_for(ada, time_zone: "America/New_York", digest_hour: 3) # 03:05 in New York on 10 November is 08:05 UTC

    expect { described_class.perform_now(morning) }.to have_enqueued_mail(NotificationDigestMailer, :daily)
    expect { described_class.perform_now(morning + 1.hour) }.not_to have_enqueued_mail(NotificationDigestMailer, :daily)
  end

  it "sends nothing at the wrong hour, to people with the digest off, or when there is nothing new" do
    wrong_hour = digest_for(ada, digest_hour: 9)
    create(:notification_setting, user: owner) # off
    create(:notification, user: owner, project: project, task: task)
    grace = digest_for(create(:user)).user # her hour (8), but nothing is waiting for her
    create(:membership, project: project, user: grace)

    expect { described_class.perform_now(morning) }.not_to have_enqueued_mail(NotificationDigestMailer, :daily)

    expect(wrong_hour.reload.last_digest_at).to be_nil # not her hour: left alone
    expect(NotificationSetting.find_by!(user: owner).last_digest_at).to be_nil # off: left alone
    expect(NotificationSetting.find_by!(user: grace).last_digest_at).to eq(morning) # nothing to say, and the next window starts now
  end

  it "leaves out what is read, what is older than the last summary, and what they can no longer see" do
    digest_for(ada, last_digest_at: morning - 20.hours - 1.minute)
    other = create(:task, project: project, creator: owner, title: "Already read")
    create(:notification, :read, user: ada, project: project, task: other, created_at: morning - 1.hour)
    old = create(:task, project: project, creator: owner, title: "From before the last summary")
    create(:notification, user: ada, project: project, task: old, created_at: morning - 40.hours)
    secret = create(:project, owner: owner, name: "Secret")
    create(:notification, user: ada, project: secret, task: create(:task, project: secret, creator: owner, title: "Hidden"), created_at: morning - 1.hour)

    perform_enqueued_jobs { described_class.perform_now(morning) }

    body = ActionMailer::Base.deliveries.sole.body.to_s
    expect(body).to include("Apollo", "Land on the moon")
    expect(body).not_to include("Already read", "From before the last summary", "Secret", "Hidden")
  end

  it "does not send twice when two runs overlap" do
    digest_for(ada)

    2.times { described_class.perform_now(morning) }

    expect(enqueued_jobs.count { |job| job["arguments"].first == "NotificationDigestMailer" }).to eq(1)
  end

  it "re-checks under the lock, because another run may have sent it since this one looked" do
    setting = digest_for(ada)
    stale = NotificationSetting.find(setting.id) # what a second run loaded before the first finished
    described_class.perform_now(morning)
    enqueued_jobs.clear
    create(:notification, user: ada, project: project, task: create(:task, project: project, creator: owner), created_at: morning + 1.second) # something to send, if it were due

    described_class.new.send(:send_digest, stale, morning)

    expect(enqueued_jobs.count { |job| job["arguments"].first == "NotificationDigestMailer" }).to eq(0)
  end
end
