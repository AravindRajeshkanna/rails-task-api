require "rails_helper"

# The model validations are the first line of defense; these prove the database refuses the same
# data when something skips them (insert_all, update_columns, SQL from a console or another service).
RSpec.describe "Database constraints" do
  # Created up front: rows made inside a savepoint that fails are rolled back with it.
  let!(:project) { create(:project) }
  let!(:task) { create(:task, project: project) }
  let!(:user) { create(:user) }
  let!(:tag) { create(:tag, project: project) }
  let!(:membership) { create(:membership, project: project) }

  def write(record, **columns) = record.update_columns(columns)

  # A failed statement aborts the surrounding (test) transaction, so each attempt gets a savepoint.
  def violating(constraint, &attempt)
    expect { ActiveRecord::Base.transaction(requires_new: true, &attempt) }
      .to raise_error(ActiveRecord::CheckViolation, /#{constraint}/)
  end

  it "rejects an unknown task status or priority" do
    violating("tasks_status_valid") { write(task, status: 9) }
    violating("tasks_priority_valid") { write(task, priority: -1) }
  end

  it "rejects blank text where a name or title is required" do
    violating("tasks_title_present") { write(task, title: "   ") }
    violating("projects_name_present") { write(project, name: "") }
    violating("users_name_present") { write(user, name: " ") }
    violating("tags_name_present") { write(tag, name: "") }
  end

  it "rejects negative counters" do
    violating("tasks_counters_non_negative") { write(task, comments_count: -1) }
    violating("tasks_counters_non_negative") { write(task, lock_version: -1) }
  end

  it "rejects a membership role the policies do not know" do
    violating("memberships_role_valid") { write(membership, role: "owner") }
  end

  it "rejects a bulk insert that skips validations" do
    now = Time.current
    row = { project_id: project.id, creator_id: project.owner_id, title: "", status: 0, priority: 1, created_at: now, updated_at: now }

    violating("tasks_title_present") { Task.insert_all([ row ]) }
  end

  it "has every constraint validated, so old rows are covered too" do
    unvalidated = ActiveRecord::Base.connection.select_values(<<~SQL)
      SELECT conname FROM pg_constraint WHERE contype = 'c' AND NOT convalidated
    SQL

    expect(unvalidated).to be_empty
  end

  it "has the index behind the default task listing" do
    expect(ActiveRecord::Base.connection.index_name_exists?(:tasks, "index_tasks_on_project_id_and_created_at_when_kept")).to be(true)
  end
end
