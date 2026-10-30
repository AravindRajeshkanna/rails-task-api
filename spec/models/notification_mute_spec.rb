require "rails_helper"

RSpec.describe NotificationMute do
  let(:user) { create(:user) }
  let(:project) { create(:project, owner: user) }

  it "mutes a kind, a project, or a kind in a project, and never nothing" do
    expect(build(:notification_mute, user: user, kind: "task.due_soon")).to be_valid
    expect(build(:notification_mute, user: user, kind: nil, project: project)).to be_valid
    expect(build(:notification_mute, user: user, kind: "task.due_soon", project: project)).to be_valid
    expect(build(:notification_mute, user: user, kind: nil, project: nil)).not_to be_valid
    expect(build(:notification_mute, user: user, kind: "task.exploded")).not_to be_valid
  end

  it "covers exactly what it names" do
    everywhere = build(:notification_mute, kind: "comment.created")
    whole_project = build(:notification_mute, kind: nil, project_id: 5)
    one_kind_there = build(:notification_mute, kind: "comment.created", project_id: 5)

    expect(everywhere.covers?("comment.created", 5)).to be(true)
    expect(everywhere.covers?("task.assigned", 5)).to be(false)
    expect(whole_project.covers?("task.assigned", 5)).to be(true)
    expect(whole_project.covers?("task.assigned", 6)).to be(false)
    expect(one_kind_there.covers?("comment.created", 5)).to be(true)
    expect(one_kind_there.covers?("comment.created", 6)).to be(false)
    expect(one_kind_there.covers?("task.assigned", 5)).to be(false)
  end

  it "is not stored twice, including when one side is empty (validation, and the index behind it)" do
    create(:notification_mute, user: user, kind: nil, project: project)
    create(:notification_mute, user: user, kind: "comment.created", project: nil)

    expect(build(:notification_mute, user: user, kind: nil, project: project)).not_to be_valid
    expect(build(:notification_mute, user: user, kind: "comment.created", project: nil)).not_to be_valid
    row = { user_id: user.id, project_id: project.id, kind: nil, created_at: Time.current }
    expect { described_class.transaction(requires_new: true) { described_class.insert_all!([ row ]) } }.to raise_error(ActiveRecord::RecordNotUnique)
    expect(build(:notification_mute, user: create(:user), kind: "comment.created", project: nil)).to be_valid # someone else's
  end

  it "goes away with the project" do
    create(:notification_mute, user: user, kind: nil, project: project)

    expect { project.destroy! }.to change(described_class, :count).by(-1)
  end
end
