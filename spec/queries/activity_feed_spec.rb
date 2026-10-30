require "rails_helper"

RSpec.describe ActivityFeed do
  let(:user) { create(:user) }
  let(:projects) { Array.new(4) { create(:project, owner: user) } }
  let(:types) { Api::V1::ActivitiesController::ACTIVITY_TYPES }

  # Events with controlled times, several per instant and per project, so ties across projects are exercised. Inserted directly: these tests
  # are about reading them back, not about what makes them (AuditEvent validates that its subject exists).
  def event(project, at, type: "Task")
    AuditEvent.insert_all!([ { project_id: project.id, auditable_type: type, auditable_id: 1, action: "update", created_at: at } ])
  end

  before do
    base = Time.utc(2026, 10, 1, 12)
    projects.each_with_index do |project, i|
      30.times { |n| event(project, base + ((n + i) / 3).minutes) } # three events at each of several instants, shifted per project
    end
  end

  # What the straightforward query returns: the order the feed has to reproduce.
  def reference(scope_projects = projects, kinds = types)
    AuditEvent.where(project_id: scope_projects.map(&:id), auditable_type: kinds).order(created_at: :desc, id: :desc).to_a
  end

  def walk(feed_projects, limit:, kinds: types)
    seen = []
    after = nil
    loop do
      page = described_class.new(Project.where(id: feed_projects.map(&:id)), types: kinds, after: after).call.limit(limit + 1).to_a
      seen.concat(page.first(limit))
      break if page.size <= limit

      after = [ page[limit - 1].created_at, page[limit - 1].id ]
    end
    seen
  end

  it "gives the same events in the same order as the single query, across projects, however it is paged" do
    expect(walk(projects, limit: 7)).to eq(reference)
    expect(walk(projects, limit: 1)).to eq(reference)
    expect(walk(projects, limit: 100)).to eq(reference)
  end

  it "breaks ties by id, so events in the same instant are neither skipped nor repeated at a page boundary" do
    ids = walk(projects, limit: 5).map(&:id)

    expect(ids).to eq(ids.uniq)
    expect(ids.size).to eq(reference.size) # the 120 inserted, and the events creating the projects made
  end

  it "reads only the projects it is given, and only the types asked for" do
    event(projects.first, Time.utc(2026, 10, 2), type: "Comment")
    elsewhere = create(:project)
    event(elsewhere, Time.utc(2026, 10, 3))

    expect(walk(projects.first(2), limit: 9)).to eq(reference(projects.first(2)))
    expect(walk(projects, limit: 9, kinds: %w[Comment])).to eq(reference(projects, %w[Comment]))
    expect(walk(projects, limit: 9).map(&:project_id)).not_to include(elsewhere.id)
  end

  it "asks each project for at most one page's worth, however long its history" do
    sql = described_class.new(Project.where(id: projects.map(&:id)), types: types).call.to_sql

    expect(sql).to include("CROSS JOIN LATERAL").and include("LIMIT #{Pagination::MAX_LIMIT + 1}")
  end
end
