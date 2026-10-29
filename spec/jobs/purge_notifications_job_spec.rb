require "rails_helper"

RSpec.describe PurgeNotificationsJob do
  it "removes read notifications after 30 days and unread ones after 180, and nothing newer" do
    user = create(:user)
    project = create(:project, owner: user)
    task = create(:task, project: project)
    make = ->(**attributes) { create(:notification, user: user, project: project, task: task, **attributes) }

    old_read = make.call(read_at: 31.days.ago, created_at: 40.days.ago)
    recent_read = make.call(read_at: 29.days.ago, created_at: 40.days.ago)
    old_unread = make.call(created_at: 181.days.ago)
    recent_unread = make.call(created_at: 100.days.ago)

    described_class.perform_now

    expect(Notification.pluck(:id)).to contain_exactly(recent_read.id, recent_unread.id)
    expect(Notification.where(id: [ old_read.id, old_unread.id ])).to be_empty
  end

  it "is scheduled every day" do
    schedule = YAML.load_file(Rails.root.join("config/recurring.yml")).dig("production", "prune_notifications")

    expect(schedule).to include("class" => "PurgeNotificationsJob", "schedule" => "every day at 3:30am")
  end
end
