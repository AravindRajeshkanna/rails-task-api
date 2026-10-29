require "rails_helper"

RSpec.describe Project do
  describe "validations and associations" do
    subject { build(:project) }

    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_length_of(:name).is_at_most(120) }
    it { is_expected.to belong_to(:owner).class_name("User") }
    it { is_expected.to have_many(:memberships).dependent(:destroy) }
    it { is_expected.to have_many(:tasks).dependent(:destroy) }
    it { is_expected.to have_many(:tags).dependent(:destroy) }
    it { is_expected.to have_many(:webhooks).dependent(:destroy) }
  end

  it "makes the owner an admin member on creation" do
    project = create(:project)

    membership = project.memberships.sole
    expect(membership).to have_attributes(user: project.owner, role: "admin")
  end

  describe "soft deletion" do
    let!(:project) { create(:project) }

    it "hides discarded projects from .kept and brings them back on undiscard" do
      expect(project.discard).to be(true)
      expect(project).to be_discarded
      expect(Project.kept).not_to include(project)
      expect(Project.discarded).to include(project)

      project.undiscard
      expect(Project.kept).to include(project)
    end

    it "does nothing when discarding twice" do
      project.discard
      expect(project.discard).to be(false)
    end
  end

  describe "#stats" do
    let(:project) { create(:project) }

    it "counts kept tasks by status and overdue tasks" do
      create(:task, project:)
      create(:task, :in_progress, project:)
      create(:task, :done, project:, due_on: 3.days.ago) # done tasks are never overdue
      create(:task, project:, due_on: 2.days.ago)
      create(:task, :discarded, project:)

      expect(project.stats).to eq("todo" => 2, "in_progress" => 1, "done" => 1, "overdue" => 1)
    end

    it "is cached and refreshed when a task changes" do
      store = ActiveSupport::Cache::MemoryStore.new
      allow(Rails).to receive(:cache).and_return(store)
      task = create(:task, project:)

      task_queries = lambda do
        count = 0
        counter = ->(*, payload) { count += 1 if payload[:sql].include?('FROM "tasks"') }
        ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { project.reload.stats }
        count
      end

      expect(task_queries.call).to be > 0 # first call hits the database
      expect(task_queries.call).to eq(0)  # second call is served from the cache

      task.update!(status: :done) # touches the project, changing its cache key
      expect(project.reload.stats).to include("todo" => 0, "done" => 1)
    end
  end

  describe "auditing" do
    let(:actor) { create(:user) }

    it "records create, update and discard with the actor" do
      Current.session = Session.start_for!(actor).first
      project = create(:project, owner: actor, name: "Alpha")
      project.update!(name: "Beta")
      project.discard

      events = project.audit_trail.order(:id)
      expect(events.map(&:action)).to eq(%w[create update discard])
      expect(events.map(&:actor)).to all(eq(actor))
      expect(events.second.audit_changes).to eq("name" => %w[Alpha Beta])
      expect(events.first.project_id).to eq(project.id)
    end
  end

  describe "events" do
    it "emits created, updated, discarded and restored, but not for task-driven touches" do
      project = nil
      recorder = record_events do
        project = create(:project)
        project.update!(name: "Renamed")
        project.discard
        project.undiscard
        create(:task, project:) # touches the project
      end

      project_events = recorder.names.grep(/\Aproject\./)
      expect(project_events).to eq(%w[project.created project.updated project.discarded project.restored])
    end
  end
end
