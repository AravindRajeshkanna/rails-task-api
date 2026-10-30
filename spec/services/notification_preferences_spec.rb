require "rails_helper"

RSpec.describe NotificationPreferences do
  let(:ada) { create(:user) }
  let(:grace) { create(:user) }
  let(:project) { create(:project, owner: ada) }

  it "lets everything through for someone who set nothing" do
    preferences = described_class.new([ ada.id ])

    expect(preferences.inbox?(ada.id, "task.assigned", project.id)).to be(true)
    expect(preferences.email?(ada.id, "task.assigned", project.id)).to be(true)
  end

  it "applies a person's mutes to them and to nobody else" do
    create(:notification_mute, user: ada, kind: "comment.created", project: nil)
    preferences = described_class.new([ ada.id, grace.id ])

    expect(preferences.inbox?(ada.id, "comment.created", project.id)).to be(false)
    expect(preferences.email?(ada.id, "comment.created", project.id)).to be(false)
    expect(preferences.inbox?(ada.id, "task.assigned", project.id)).to be(true)
    expect(preferences.inbox?(grace.id, "comment.created", project.id)).to be(true)
  end

  it "stops the email but not the inbox when someone takes a daily digest" do
    create(:notification_setting, :daily, user: ada)
    preferences = described_class.new(ada.id)

    expect(preferences.inbox?(ada.id, "task.assigned", project.id)).to be(true)
    expect(preferences.email?(ada.id, "task.assigned", project.id)).to be(false)
  end

  it "loads a whole batch in two queries, however many people and mutes" do
    users = create_list(:user, 5)
    users.each { |user| create(:notification_mute, user: user, kind: "task.completed") }

    ids = users.map(&:id)
    project_id = project.id
    queries = count_queries { described_class.new(ids).email?(ids.first, "task.completed", project_id) }

    expect(queries).to eq(2)
  end
end
