require "rails_helper"

RSpec.describe Task do
  let(:project) { create(:project) }
  let(:owner) { project.owner }

  describe "validations and associations" do
    subject { build(:task, project:) }

    it { is_expected.to belong_to(:project) }
    it { is_expected.to belong_to(:creator).class_name("User") }
    it { is_expected.to belong_to(:assignee).class_name("User").optional }
    it { is_expected.to have_many(:comments).dependent(:destroy) }
    it { is_expected.to have_many(:tags).through(:taggings) }
    it { is_expected.to validate_presence_of(:title) }
    it { is_expected.to validate_length_of(:title).is_at_most(200) }
    it { is_expected.to define_enum_for(:status).with_values(todo: 0, in_progress: 1, done: 2) }
    it { is_expected.to define_enum_for(:priority).with_values(low: 0, medium: 1, high: 2, urgent: 3) }
  end

  it "defaults to todo / medium" do
    expect(Task.new).to have_attributes(status: "todo", priority: "medium")
  end

  describe "assignee" do
    it "must be a member of the project" do
      outsider = create(:user)
      task = build(:task, project:, assignee: outsider)

      expect(task).not_to be_valid
      expect(task.errors[:assignee]).to include("must be a member of the project")
    end

    it "may be any project member" do
      member = create(:membership, project:).user

      expect(build(:task, project:, assignee: member)).to be_valid
    end

    it "emails a newly assigned member, but not when assigning yourself" do
      member = create(:membership, project:).user

      expect { create(:task, project:, assignee: member) }
        .to have_enqueued_mail(TaskMailer, :assigned)

      Current.session = Session.start_for!(member).first
      expect { create(:task, project:, assignee: member) }
        .not_to have_enqueued_mail(TaskMailer, :assigned)
    end
  end

  describe "completion tracking" do
    it "stamps completed_at when done and clears it when reopened" do
      task = create(:task, project:)
      expect(task.completed_at).to be_nil

      task.update!(status: :done)
      expect(task.completed_at).to be_within(5.seconds).of(Time.current)

      task.update!(status: :in_progress)
      expect(task.completed_at).to be_nil
    end
  end

  describe "optimistic locking" do
    it "rejects a stale update" do
      task = create(:task, project:)
      stale = Task.find(task.id)
      task.update!(title: "First")

      expect { stale.update!(title: "Second") }.to raise_error(ActiveRecord::StaleObjectError)
    end
  end

  describe "#overdue?" do
    it "is true only for unfinished tasks past their due date" do
      expect(build(:task, due_on: 1.day.ago.to_date)).to be_overdue
      expect(build(:task, due_on: Date.current)).not_to be_overdue
      expect(build(:task, :done, due_on: 1.day.ago.to_date)).not_to be_overdue
      expect(build(:task, due_on: nil)).not_to be_overdue
    end
  end

  describe "scopes" do
    let!(:overdue) { create(:task, project:, title: "Fix login bug", due_on: 2.days.ago) }
    let!(:upcoming) { create(:task, project:, title: "Write docs", description: "Mention the LOGIN flow", due_on: 2.days.from_now) }
    let!(:done) { create(:task, :done, project:, title: "Ship it", due_on: 5.days.ago) }

    it ".overdue excludes done and future tasks" do
      expect(Task.overdue).to contain_exactly(overdue)
    end

    it ".search matches title and description case-insensitively" do
      expect(Task.search("login")).to contain_exactly(overdue, upcoming)
      expect(Task.search("ship")).to contain_exactly(done)
    end

    it ".search treats % and _ literally" do
      create(:task, project:, title: "100% done")

      expect(Task.search("100%").map(&:title)).to eq([ "100% done" ])
      expect(Task.search("%")).to contain_exactly(have_attributes(title: "100% done"))
    end

    it ".with_tag_names matches any of the tags without duplicating rows" do
      overdue.update!(tag_names: %w[bug api])
      upcoming.update!(tag_names: %w[docs])

      expect(Task.with_tag_names(%w[bug api])).to contain_exactly(overdue)
      expect(Task.with_tag_names(%w[bug docs])).to contain_exactly(overdue, upcoming)
    end
  end

  describe "#tag_names=" do
    it "finds or creates the project's tags, normalizing and de-duplicating names" do
      existing = create(:tag, project:, name: "bug")
      task = create(:task, project:)

      expect { task.update!(tag_names: [ "Bug", " api ", "API", "" ]) }.to change(Tag, :count).by(1)

      expect(task.reload.tags.map(&:name)).to contain_exactly("bug", "api")
      expect(task.tags).to include(existing)
    end

    it "replaces the previous tags" do
      task = create(:task, project:, tag_names: %w[a b])
      task.update!(tag_names: %w[b c])

      expect(task.reload.tags.map(&:name)).to contain_exactly("b", "c")
    end
  end

  describe "attachments" do
    let(:task) { create(:task, project:) }

    it "accepts permitted file types" do
      task.attachments.attach(io: file_fixture("notes.txt").open, filename: "notes.txt", content_type: "text/plain")

      expect(task).to be_valid
    end

    it "rejects unsupported types" do
      task.attachments.attach(io: file_fixture("installer.exe").open, filename: "installer.exe", content_type: "application/x-msdownload")

      expect(task).not_to be_valid
      expect(task.errors[:attachments].first).to include("unsupported type")
    end

    it "rejects oversized files" do
      stub_const("Task::MAX_ATTACHMENT_SIZE", 1.byte)
      task.attachments.attach(io: file_fixture("notes.txt").open, filename: "notes.txt", content_type: "text/plain")

      expect(task).not_to be_valid
      expect(task.errors[:attachments].first).to include("exceeds")
    end
  end

  describe "comments counter cache" do
    it "tracks the number of comments" do
      task = create(:task, project:)

      expect { create_list(:comment, 2, task:) }.to change { task.reload.comments_count }.from(0).to(2)
      expect { task.comments.first.destroy }.to change { task.reload.comments_count }.by(-1)
    end
  end

  describe "soft deletion and events" do
    it "emits one event per lifecycle change" do
      task = nil
      recorder = record_events do
        task = create(:task, project:)
        task.update!(title: "Renamed")
        task.update!(status: :done)
        task.discard
        task.undiscard
      end

      expect(recorder.names.grep(/\Atask\./)).to eq(%w[
        task.created task.updated task.updated task.completed task.discarded task.restored
      ])
      expect(recorder.payloads("task.created").sole).to include(project_id: project.id, subject: task.to_global_id.to_s)
    end

    it "does not emit completed when status changes to something else" do
      task = create(:task, project:)
      recorder = record_events { task.update!(status: :in_progress) }

      expect(recorder.names).to eq([ "task.updated" ])
    end
  end

  describe "auditing" do
    it "records what changed and who changed it" do
      actor = project.owner
      Current.session = Session.start_for!(actor).first
      task = create(:task, project:, title: "Draft")
      task.update!(title: "Final", status: :done)

      update_event = task.audit_trail.order(:id).last
      expect(update_event).to have_attributes(action: "update", actor: actor, project_id: project.id)
      expect(update_event.audit_changes).to include("title" => %w[Draft Final], "status" => %w[todo done])
      expect(update_event.audit_changes.keys).not_to include("updated_at", "lock_version")
    end
  end
end
