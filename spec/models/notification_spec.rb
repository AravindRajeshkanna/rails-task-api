require "rails_helper"

RSpec.describe Notification do
  it { is_expected.to belong_to(:user) }
  it { is_expected.to belong_to(:project) }
  it { is_expected.to belong_to(:task) }
  it { is_expected.to validate_inclusion_of(:kind).in_array(described_class::KINDS) }

  describe "#mark_read!" do
    it "marks it read once, keeping the first time, and can undo it" do
      notification = create(:notification)

      first = notification.mark_read!.read_at
      travel(1.hour) { expect(notification.mark_read!.read_at).to eq(first) }
      expect(notification).to be_read

      notification.mark_read!(read: false)
      expect(notification).not_to be_read
    end
  end

  it "goes with the user, the project and the task it is about, without callbacks" do
    notification = create(:notification)
    other = create(:notification)

    notification.task.destroy!
    other.project.destroy!

    expect(described_class.where(id: [ notification.id, other.id ])).to be_empty

    recipient = create(:user)
    shared = create(:project)
    create(:notification, user: recipient, project: shared, task: create(:task, project: shared))
    expect { recipient.destroy! }.to change(described_class, :count).by(-1)
  end

  it "keeps the notification, without the actor, when the actor's account is deleted" do
    actor = create(:user)
    notification = create(:notification, actor: actor)

    actor.delete

    expect(notification.reload.actor_id).to be_nil
  end

  it "only allows one notification per dedupe key and person" do
    first = create(:notification, dedupe_key: "once")

    expect { create(:notification, user: first.user, project: first.project, task: first.task, dedupe_key: "once") }.to raise_error(ActiveRecord::RecordNotUnique)
    expect { create(:notification, user: first.user, project: first.project, task: first.task, dedupe_key: nil) }.not_to raise_error
  end

  it "is pushed to the recipient as soon as it is stored" do
    user = create(:user)

    expect { create(:notification, user: user) }.to have_broadcasted_to(described_class.stream_name(user.id))
      .with(a_hash_including("event" => "notification.created", "data" => a_hash_including("kind" => "task.assigned", "read" => false)))
  end
end
