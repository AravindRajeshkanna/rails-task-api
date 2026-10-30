require "swagger_helper"

RSpec.describe "Tasks API", type: :request do
  ref = OpenapiSchemas.method(:ref)
  envelope = OpenapiSchemas.method(:envelope)

  let(:owner) { create(:user) }
  let(:project) { create(:project, owner: owner) }
  let(:Authorization) { auth_headers(owner)["Authorization"] }
  let!(:task) { create(:task, project:, tag_names: %w[bug]) }

  task_body = {
    type: :object,
    properties: {
      title: { type: :string, maxLength: 200 }, description: { type: :string },
      status: { type: :string, enum: %w[todo in_progress done] }, priority: { type: :string, enum: %w[low medium high urgent] },
      due_on: { type: :string, format: :date }, assignee_id: { type: :integer, description: "Must be a project member" },
      tag_names: { type: :array, items: { type: :string }, description: "Replaces the task's tags; unknown names are created" },
      lock_version: { type: :integer, description: "Optimistic locking: a stale value returns 409" }
    }
  }

  path "/api/v1/projects/{project_id}/tasks" do
    parameter name: :project_id, in: :path, type: :integer
    let(:project_id) { project.id }

    get "List and search tasks" do
      tags "Tasks"
      description "Filters combine with AND. Invalid values return 400 with `details.parameter`."
      security [ { bearer_auth: [] } ]
      produces "application/json"
      parameter name: :status, in: :query, type: :string, required: false, description: "Comma-separated: todo, in_progress, done"
      parameter name: :priority, in: :query, type: :string, required: false, description: "Comma-separated: low, medium, high, urgent"
      parameter name: :assignee, in: :query, type: :string, required: false, description: "`me`, `unassigned` or a user id"
      parameter name: :tag, in: :query, type: :string, required: false, description: "Comma-separated tag names (any match)"
      parameter name: :due_from, in: :query, type: :string, format: :date, required: false
      parameter name: :due_to, in: :query, type: :string, format: :date, required: false
      parameter name: :overdue, in: :query, type: :boolean, required: false, description: "Only unfinished tasks past their due date"
      parameter name: :q, in: :query, type: :string, required: false, description: "Case-insensitive substring search of title and description"
      parameter name: :search, in: :query, type: :string, required: false,
                description: "Full-text search of title and description (max 200 characters): words are stemmed, `\"quoted phrases\"`, `or` and `-excluded` work. " \
                             "Best match first unless `sort` is given"
      parameter name: :sort, in: :query, type: :string, required: false,
                description: "Comma-separated columns (created_at, updated_at, due_on, priority, status, title); prefix `-` for descending. Default `-created_at`"
      parameter name: :page, in: :query, type: :integer, required: false
      parameter name: :cursor, in: :query, type: :string, required: false, allowEmptyValue: true,
                description: "Switches to keyset pagination, which costs the same at any depth and does not skip or repeat tasks when others are " \
                             "added meanwhile, but has no total. Send it empty for the first page, then `meta.next_cursor` of the previous response " \
                             "(with the same filters and sort). Only for sorts by `created_at`, `updated_at` and `title` (not by relevance, " \
                             "`priority`, `status` or `due_on`); an invalid cursor is a 400. Replaces `page`."
      parameter name: :limit, in: :query, type: :integer, required: false

      response "200", "A page of tasks (`meta` has `page`, `count`...; with `cursor`, `next_cursor` and `has_more` and no total)" do
        schema OpenapiSchemas.listing(ref.call("Task"))
        let(:tag) { "bug" }
        let(:sort) { "-priority,due_on" }
        let(:q) { task.title }
        run_test! { expect(data.pluck("id")).to eq([ task.id ]) }
      end

      response "400", "Invalid filter, sort or cursor value" do
        schema ref.call("Error")
        let(:status) { "someday" }
        run_test!
      end

      response "404", "Not a member of the project" do
        schema ref.call("Error")
        let(:Authorization) { auth_headers(create(:user))["Authorization"] }
        run_test!
      end
    end

    post "Create a task" do
      tags "Tasks"
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: task_body.merge(required: [ :title ])

      response "201", "Created" do
        schema envelope.call(ref.call("Task"))
        let(:body) { { title: "Write the docs", priority: "high", due_on: "2026-12-01", tag_names: %w[docs] } }
        run_test!
      end

      response "422", "Validation failed" do
        schema ref.call("Error")
        let(:body) { { title: "", assignee_id: create(:user).id } }
        run_test!
      end
    end
  end

  path "/api/v1/tasks/{id}" do
    parameter name: :id, in: :path, type: :integer
    let(:id) { task.id }

    get "Show a task" do
      tags "Tasks"
      security [ { bearer_auth: [] } ]
      produces "application/json"

      response("200", "The task") { schema envelope.call(ref.call("Task")); run_test! }
      response("404", "Not found") { schema ref.call("Error"); let(:id) { 0 }; run_test! }
    end

    patch "Update a task" do
      tags "Tasks"
      description "Setting `status` to `done` stamps `completed_at`; reopening clears it."
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: task_body

      response "200", "Updated" do
        schema envelope.call(ref.call("Task"))
        let(:body) { { status: "done", lock_version: task.lock_version } }
        run_test! { expect(data["completed_at"]).to be_present }
      end

      response "409", "Stale `lock_version`" do
        schema ref.call("Error")
        before { task.update!(title: "Changed elsewhere") }
        let(:body) { { title: "Mine", lock_version: 0 } }
        run_test!
      end
    end

    delete "Delete a task" do
      tags "Tasks"
      description "Soft delete (admins, or the task's creator)."
      security [ { bearer_auth: [] } ]

      response("204", "Deleted") { run_test! }
    end
  end

  path "/api/v1/tasks/{id}/restore" do
    parameter name: :id, in: :path, type: :integer
    let(:id) { task.id }

    post "Restore a deleted task" do
      tags "Tasks"
      description "Admins only."
      security [ { bearer_auth: [] } ]
      produces "application/json"
      before { task.discard }

      response "200", "Restored" do
        schema envelope.call(ref.call("Task"))
        run_test!
      end
    end
  end

  path "/api/v1/tasks/{task_id}/attachments" do
    parameter name: :task_id, in: :path, type: :integer

    post "Attach files" do
      tags "Tasks"
      description "multipart/form-data with one or more `files[]` (png, jpeg, webp, gif, pdf, txt, csv; up to 10 files of 10 MB each)."
      security [ { bearer_auth: [] } ]
      consumes "multipart/form-data"
      produces "application/json"
      parameter name: :files, in: :formData, required: true,
                schema: { type: :object, properties: { files: { type: :array, items: { type: :string, format: :binary } } }, required: [ :files ] }
      let(:task_id) { task.id }

      response "201", "Returns the updated task, including signed attachment URLs" do
        schema envelope.call(ref.call("Task"))
        let(:files) { [ fixture_file_upload("notes.txt", "text/plain") ] }
        run_test! { expect(data["attachments"].sole["filename"]).to eq("notes.txt") }
      end

      response "422", "Unsupported type or too large" do
        schema ref.call("Error")
        let(:files) { [ fixture_file_upload("installer.exe", "application/x-msdownload") ] }
        run_test!
      end
    end
  end

  path "/api/v1/attachments/{id}" do
    parameter name: :id, in: :path, type: :integer

    delete "Remove an attachment" do
      tags "Tasks"
      security [ { bearer_auth: [] } ]
      response("204", "Removed") do
        before { task.attachments.attach(io: file_fixture("notes.txt").open, filename: "notes.txt", content_type: "text/plain") }
        let(:id) { task.attachments.first.id }
        run_test!
      end
    end
  end

  path "/api/v1/tasks/{task_id}/comments" do
    parameter name: :task_id, in: :path, type: :integer
    let(:task_id) { task.id }

    get "List comments" do
      tags "Comments"
      description "Oldest first."
      security [ { bearer_auth: [] } ]
      produces "application/json"
      parameter name: :page, in: :query, type: :integer, required: false
      parameter name: :limit, in: :query, type: :integer, required: false

      response "200", "Comments" do
        schema envelope.call(ref.call("Comment"), list: true)
        run_test!
      end
    end

    post "Add a comment" do
      tags "Comments"
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: { type: :object, properties: { body: { type: :string, maxLength: 5000 } }, required: [ :body ] }

      response "201", "Created" do
        schema envelope.call(ref.call("Comment"))
        let(:body) { { body: "Looks good to me" } }
        run_test!
      end

      response "422", "Blank body" do
        schema ref.call("Error")
        let(:body) { { body: "" } }
        run_test!
      end
    end
  end

  path "/api/v1/comments/{id}" do
    parameter name: :id, in: :path, type: :integer
    let(:comment) { create(:comment, task:, user: owner) }
    let(:id) { comment.id }

    patch "Edit a comment" do
      tags "Comments"
      description "Author only."
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: { type: :object, properties: { body: { type: :string } }, required: [ :body ] }

      response "200", "Updated" do
        schema envelope.call(ref.call("Comment"))
        let(:body) { { body: "Edited" } }
        run_test!
      end
    end

    delete "Delete a comment" do
      tags "Comments"
      description "The author or a project admin."
      security [ { bearer_auth: [] } ]

      response("204", "Deleted") { run_test! }
    end
  end
end
