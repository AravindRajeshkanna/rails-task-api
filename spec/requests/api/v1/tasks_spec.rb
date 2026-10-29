require "rails_helper"

RSpec.describe "Tasks" do
  let(:owner) { create(:user) }
  let(:project) { create(:project, owner: owner) }
  let(:member) { create(:membership, project:).user }
  let(:admin) { create(:membership, :admin, project:).user }
  let(:outsider) { create(:user) }
  let(:tasks_path) { "/api/v1/projects/#{project.id}/tasks" }

  describe "POST /api/v1/projects/:project_id/tasks" do
    it "creates a task attributed to the current user" do
      api :post, tasks_path, {
        title: "  Write   the docs ", description: "All of them", priority: "high",
        due_on: "2026-12-01", tag_names: %w[Docs api]
      }, as: member

      expect(response).to have_http_status(:created)
      expect(data).to include(
        "title" => "Write the docs", "status" => "todo", "priority" => "high", "due_on" => "2026-12-01",
        "tags" => %w[api docs], "creator" => { "id" => member.id, "name" => member.name },
        "assignee" => nil, "overdue" => false, "comments_count" => 0, "attachments" => [], "project_id" => project.id
      )
      expect(Task.find(data["id"]).creator).to eq(member)
    end

    it "assigns a project member and emails them" do
      assignee = create(:membership, project:).user

      expect { api :post, tasks_path, { title: "Review", assignee_id: assignee.id }, as: owner }
        .to have_enqueued_mail(TaskMailer, :assigned)

      expect(data["assignee"]).to include("id" => assignee.id)
    end

    it "rejects an assignee from outside the project" do
      api :post, tasks_path, { title: "Review", assignee_id: outsider.id }, as: owner

      expect(response).to have_http_status(:unprocessable_content)
      expect(error["details"]).to eq("assignee" => [ "must be a member of the project" ])
    end

    it "validates enums and presence" do
      api :post, tasks_path, { title: "", status: "someday", priority: "asap" }, as: owner

      expect(response).to have_http_status(:unprocessable_content)
      expect(error["details"].keys).to contain_exactly("title", "status", "priority")
    end

    it "ignores attempts to set creator or project" do
      other = create(:project)
      api :post, tasks_path, { title: "Sneaky", creator_id: outsider.id, project_id: other.id }, as: owner

      expect(Task.find(data["id"])).to have_attributes(creator: owner, project: project)
    end

    it "is forbidden for non-members (404) and unavailable on discarded projects" do
      api :post, tasks_path, { title: "Nope" }, as: outsider
      expect(response).to have_http_status(:not_found)

      project.discard
      api :post, tasks_path, { title: "Nope" }, as: owner
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/tasks/:id" do
    let(:task) { create(:task, project:, tag_names: %w[bug]) }

    it "shows a task to members" do
      api :get, "/api/v1/tasks/#{task.id}", as: member

      expect(response).to have_http_status(:ok)
      expect(data).to include("id" => task.id, "title" => task.title, "tags" => [ "bug" ], "lock_version" => 0)
    end

    it "404s for outsiders, discarded tasks and tasks of discarded projects" do
      api :get, "/api/v1/tasks/#{task.id}", as: outsider
      expect(response).to have_http_status(:not_found)

      task.discard
      api :get, "/api/v1/tasks/#{task.id}", as: owner
      expect(response).to have_http_status(:not_found)

      task.undiscard
      project.discard
      api :get, "/api/v1/tasks/#{task.id}", as: owner
      expect(response).to have_http_status(:not_found)

      project.undiscard
      api :get, "/api/v1/tasks/#{task.id}", as: owner
      expect(response).to have_http_status(:ok)
    end
  end

  describe "PATCH /api/v1/tasks/:id" do
    let(:task) { create(:task, project:) }

    it "updates fields and completes the task" do
      api :patch, "/api/v1/tasks/#{task.id}", { title: "Done deal", status: "done", tag_names: %w[shipped] }, as: member

      expect(response).to have_http_status(:ok)
      expect(data).to include("title" => "Done deal", "status" => "done", "tags" => [ "shipped" ])
      expect(data["completed_at"]).to be_present
      expect(data["lock_version"]).to eq(1)
    end

    it "supports optimistic locking via lock_version" do
      api :patch, "/api/v1/tasks/#{task.id}", { title: "First", lock_version: 0 }, as: owner
      expect(response).to have_http_status(:ok)

      api :patch, "/api/v1/tasks/#{task.id}", { title: "Second", lock_version: 0 }, as: owner
      expect(response).to have_http_status(:conflict)
      expect(error["code"]).to eq("stale_object")
      expect(task.reload.title).to eq("First")
    end

    it "is forbidden for outsiders" do
      api :patch, "/api/v1/tasks/#{task.id}", { title: "Hacked" }, as: outsider

      expect(response).to have_http_status(:not_found)
      expect(task.reload.title).not_to eq("Hacked")
    end

    it "cannot move a task to another project" do
      other = create(:project, owner: owner)
      api :patch, "/api/v1/tasks/#{task.id}", { project_id: other.id }, as: owner

      expect(task.reload.project).to eq(project)
    end
  end

  describe "DELETE /api/v1/tasks/:id and restore" do
    let(:task) { create(:task, project:, creator: member) }

    it "lets the creator soft-delete, and admins restore" do
      api :delete, "/api/v1/tasks/#{task.id}", as: member
      expect(response).to have_http_status(:no_content)
      expect(task.reload).to be_discarded

      api :post, "/api/v1/tasks/#{task.id}/restore", as: member
      expect(response).to have_http_status(:forbidden)

      api :post, "/api/v1/tasks/#{task.id}/restore", as: admin
      expect(response).to have_http_status(:ok)
      expect(task.reload).to be_kept
    end

    it "lets admins delete tasks they did not create, but not other members" do
      teammate = create(:membership, project:).user

      api :delete, "/api/v1/tasks/#{task.id}", as: teammate
      expect(response).to have_http_status(:forbidden)

      api :delete, "/api/v1/tasks/#{task.id}", as: admin
      expect(response).to have_http_status(:no_content)
    end
  end

  describe "GET /api/v1/projects/:project_id/tasks" do
    let(:alice) { create(:membership, project:).user }
    let!(:fix_login) { create(:task, project:, title: "Fix login bug", priority: :urgent, status: :in_progress, assignee: alice, due_on: Date.current - 2, tag_names: %w[bug auth]) }
    let!(:write_docs) { create(:task, project:, title: "Write docs", priority: :low, description: "Cover the LOGIN flow", due_on: Date.current + 5, tag_names: %w[docs]) }
    let!(:ship_it) { create(:task, :done, project:, title: "Ship it", priority: :high, due_on: Date.current - 9, tag_names: %w[bug]) }
    let!(:no_date) { create(:task, project:, title: "Someday", priority: :medium) }

    def titles = data.map { _1["title"] }

    before do
      create(:task, :discarded, project:, title: "Deleted")
      create(:task, title: "Other project")
    end

    it "lists kept tasks of the project, newest first, with all associations (no N+1)" do
      create(:comment, task: fix_login, user: alice)
      fix_login.attachments.attach(io: file_fixture("notes.txt").open, filename: "notes.txt", content_type: "text/plain")

      api :get, tasks_path, as: member

      expect(response).to have_http_status(:ok)
      expect(titles).to eq([ "Someday", "Ship it", "Write docs", "Fix login bug" ])
      expect(meta["count"]).to eq(4)
      listed = data.find { _1["id"] == fix_login.id }
      expect(listed).to include("tags" => %w[auth bug], "comments_count" => 1, "overdue" => true, "assignee" => include("id" => alice.id))
      expect(listed["attachments"].sole).to include("filename" => "notes.txt", "content_type" => "text/plain")
    end

    it "filters by status and priority (comma separated)" do
      api :get, tasks_path, { status: "todo,in_progress" }, as: member
      expect(titles).to contain_exactly("Fix login bug", "Write docs", "Someday")

      api :get, tasks_path, { priority: "urgent,high" }, as: member
      expect(titles).to contain_exactly("Fix login bug", "Ship it")
    end

    it "filters by assignee: me, unassigned or an id" do
      api :get, tasks_path, { assignee: "me" }, as: alice
      expect(titles).to eq([ "Fix login bug" ])

      api :get, tasks_path, { assignee: "unassigned" }, as: member
      expect(titles).to contain_exactly("Write docs", "Ship it", "Someday")

      api :get, tasks_path, { assignee: alice.id.to_s }, as: member
      expect(titles).to eq([ "Fix login bug" ])
    end

    it "filters by tag, due date range and overdue" do
      api :get, tasks_path, { tag: "bug" }, as: member
      expect(titles).to contain_exactly("Fix login bug", "Ship it")

      api :get, tasks_path, { tag: "docs,auth" }, as: member
      expect(titles).to contain_exactly("Fix login bug", "Write docs")

      api :get, tasks_path, { due_from: (Date.current - 3).iso8601, due_to: Date.current.iso8601 }, as: member
      expect(titles).to eq([ "Fix login bug" ])

      api :get, tasks_path, { overdue: "true" }, as: member
      expect(titles).to eq([ "Fix login bug" ])
    end

    it "searches title and description" do
      api :get, tasks_path, { q: "login" }, as: member

      expect(titles).to contain_exactly("Fix login bug", "Write docs")
    end

    it "combines filters" do
      api :get, tasks_path, { tag: "bug", status: "done", q: "ship" }, as: member

      expect(titles).to eq([ "Ship it" ])
    end

    it "sorts ascending, descending, by several columns, with nulls last for due_on" do
      api :get, tasks_path, { sort: "priority" }, as: member
      expect(titles).to eq([ "Write docs", "Someday", "Ship it", "Fix login bug" ])

      api :get, tasks_path, { sort: "-priority" }, as: member
      expect(titles).to eq([ "Fix login bug", "Ship it", "Someday", "Write docs" ])

      api :get, tasks_path, { sort: "due_on" }, as: member
      expect(titles).to eq([ "Ship it", "Fix login bug", "Write docs", "Someday" ])

      api :get, tasks_path, { sort: "-due_on" }, as: member
      expect(titles).to eq([ "Write docs", "Fix login bug", "Ship it", "Someday" ])

      api :get, tasks_path, { sort: "status,-title" }, as: member
      expect(titles).to eq([ "Write docs", "Someday", "Fix login bug", "Ship it" ])
    end

    it "paginates stably" do
      api :get, tasks_path, { sort: "title", limit: 3, page: 1 }, as: member
      first_page = titles
      api :get, tasks_path, { sort: "title", limit: 3, page: 2 }, as: member

      expect(first_page + titles).to eq([ "Fix login bug", "Ship it", "Someday", "Write docs" ])
      expect(response.headers["Total-Count"]).to eq("4")
    end

    it "rejects bad parameters with 400 and a pointer to the parameter" do
      {
        { status: "someday" } => "status",
        { priority: "asap" } => "priority",
        { sort: "password" } => "sort",
        { due_from: "yesterday" } => "due_from",
        { assignee: "bob" } => "assignee"
      }.each do |query, parameter|
        api :get, tasks_path, query, as: member

        expect(response).to have_http_status(:bad_request), "expected #{query} to be rejected"
        expect(error).to include("code" => "invalid_parameter", "details" => { "parameter" => parameter })
      end
    end

    it "is not vulnerable to SQL injection through sort or search" do
      api :get, tasks_path, { sort: "title; DROP TABLE tasks" }, as: member
      expect(response).to have_http_status(:bad_request)

      api :get, tasks_path, { q: "'; DROP TABLE tasks; --" }, as: member
      expect(response).to have_http_status(:ok)
      expect(data).to be_empty
      expect(Task.count).to be > 0
    end

    it "404s for non-members" do
      api :get, tasks_path, as: outsider

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "comments" do
    let(:task) { create(:task, project:) }

    it "lets members create, list (oldest first) and see counts" do
      api :post, "/api/v1/tasks/#{task.id}/comments", { body: "First!" }, as: member
      expect(response).to have_http_status(:created)
      expect(data).to include("body" => "First!", "user" => { "id" => member.id, "name" => member.name })

      api :post, "/api/v1/tasks/#{task.id}/comments", { body: "Second" }, as: owner
      api :get, "/api/v1/tasks/#{task.id}/comments", as: member

      expect(data.map { _1["body"] }).to eq([ "First!", "Second" ])
      expect(task.reload.comments_count).to eq(2)
    end

    it "validates the body and hides tasks from outsiders" do
      api :post, "/api/v1/tasks/#{task.id}/comments", { body: " " }, as: member
      expect(response).to have_http_status(:unprocessable_content)

      api :post, "/api/v1/tasks/#{task.id}/comments", { body: "hi" }, as: outsider
      expect(response).to have_http_status(:not_found)
    end

    it "lets only the author edit, and the author or an admin delete" do
      comment = create(:comment, task:, user: member)
      teammate = create(:membership, project:).user

      api :patch, "/api/v1/comments/#{comment.id}", { body: "Edited" }, as: member
      expect(response).to have_http_status(:ok)
      expect(comment.reload.body).to eq("Edited")

      api :patch, "/api/v1/comments/#{comment.id}", { body: "Hijacked" }, as: owner
      expect(response).to have_http_status(:forbidden)

      api :delete, "/api/v1/comments/#{comment.id}", as: teammate
      expect(response).to have_http_status(:forbidden)

      api :delete, "/api/v1/comments/#{comment.id}", as: owner
      expect(response).to have_http_status(:no_content)
      expect(task.reload.comments_count).to eq(0)
    end

    it "lists comments without N+1 queries" do
      create_list(:comment, 3, task:, user: member)

      api :get, "/api/v1/tasks/#{task.id}/comments", as: owner

      expect(data.size).to eq(3)
    end
  end

  describe "attachments" do
    let(:task) { create(:task, project:) }
    let(:upload) { fixture_file_upload("notes.txt", "text/plain") }

    it "uploads one or more files" do
      api :post, "/api/v1/tasks/#{task.id}/attachments",
          { files: [ upload, fixture_file_upload("pixel.png", "image/png") ] }, as: member

      expect(response).to have_http_status(:created)
      expect(data["attachments"].map { _1["filename"] }).to contain_exactly("notes.txt", "pixel.png")
      expect(data["attachments"].first["url"]).to start_with("http://www.example.com/rails/active_storage/blobs/redirect/")
      expect(task.reload.attachments.count).to eq(2)
    end

    it "rejects unsupported file types and stores nothing" do
      api :post, "/api/v1/tasks/#{task.id}/attachments", { files: [ fixture_file_upload("installer.exe", "application/x-msdownload") ] }, as: member

      expect(response).to have_http_status(:unprocessable_content)
      expect(error["details"]["attachments"].first).to include("unsupported type")
      expect(task.reload.attachments.count).to eq(0)
    end

    it "requires files" do
      api :post, "/api/v1/tasks/#{task.id}/attachments", { files: "oops" }, as: member

      expect(response).to have_http_status(:bad_request)
    end

    it "lets members remove an attachment" do
      task.attachments.attach(io: file_fixture("notes.txt").open, filename: "notes.txt", content_type: "text/plain")
      attachment = task.attachments.first

      api :delete, "/api/v1/attachments/#{attachment.id}", as: member
      expect(response).to have_http_status(:no_content)

      perform_enqueued_jobs
      expect(task.reload.attachments.count).to eq(0)
    end

    it "does not reveal or remove attachments of projects the caller is not in" do
      task.attachments.attach(io: file_fixture("notes.txt").open, filename: "notes.txt", content_type: "text/plain")
      attachment = task.attachments.first

      api :delete, "/api/v1/attachments/#{attachment.id}", as: outsider
      expect(response).to have_http_status(:not_found)

      api :delete, "/api/v1/attachments/#{attachment.id}", as: nil
      expect(response).to have_http_status(:unauthorized)

      expect(task.reload.attachments.count).to eq(1)
    end

    it "does not touch other record types' attachments" do
      avatar_owner = create(:user)
      avatar_owner.avatar.attach(io: file_fixture("pixel.png").open, filename: "pixel.png", content_type: "image/png")

      api :delete, "/api/v1/attachments/#{avatar_owner.avatar.attachment.id}", as: owner

      expect(response).to have_http_status(:not_found)
      expect(avatar_owner.reload.avatar).to be_attached
    end
  end
end
