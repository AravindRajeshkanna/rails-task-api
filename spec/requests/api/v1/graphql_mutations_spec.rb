require "rails_helper"

# The five GraphQL mutations are the REST writes reached another way (Mutations::BaseMutation). These examples hold them to that: what each does,
# who may do it, that the same input fails the same way over both, and that nothing escapes the rules REST has.
RSpec.describe "GraphQL mutations" do
  let(:ada) { create(:user, name: "Ada") }       # owner and admin of the project
  let(:grace) { create(:user, name: "Grace") }   # a plain member
  let(:heidi) { create(:user, name: "Heidi") }   # a plain member too
  let(:outsider) { create(:user) }
  let!(:project) { create(:project, owner: ada, name: "Apollo") }
  let!(:task) { create(:task, project: project, creator: ada, title: "Land on the moon") }

  before do
    create(:membership, project: project, user: grace)
    create(:membership, project: project, user: heidi)
  end

  def gql(query, variables: nil, as: ada)
    api :post, "/api/v1/graphql", { query: query, variables: variables }.compact, as: as
  end

  def result = json.fetch("data")
  def errors = json.fetch("errors")
  def codes = errors.map { |error| error.dig("extensions", "code") }

  describe "createTask" do
    let(:mutation) do
      <<~GQL
        mutation($input: ID!, $title: String!, $assignee: ID, $tags: [String!]) {
          createTask(projectId: $input, title: $title, priority: HIGH, dueOn: "2026-12-01", assigneeId: $assignee, tagNames: $tags) {
            task { id title status priority dueOn tags creator { name } assignee { name } project { name } }
            errors { field message }
          }
        }
      GQL
    end

    it "creates the task as the caller, with the defaults and the tags REST gives" do
      expect { gql(mutation, variables: { input: project.id.to_s, title: "Write the docs", assignee: grace.id.to_s, tags: %w[docs Bug] }, as: grace) }.to change(Task, :count).by(1)

      payload = result.fetch("createTask")
      expect(payload["errors"]).to eq([])
      expect(payload["task"]).to include("title" => "Write the docs", "status" => "TODO", "priority" => "HIGH", "dueOn" => "2026-12-01", "tags" => %w[bug docs],
                                         "creator" => { "name" => "Grace" }, "assignee" => { "name" => "Grace" }, "project" => { "name" => "Apollo" })
      expect(Task.find(payload.dig("task", "id")).creator).to eq(grace)
    end

    it "leaves the same trail as REST: an audit event by the caller, and the events other services and the inbox get" do
      gql(mutation, variables: { input: project.id.to_s, title: "Review", assignee: heidi.id.to_s }, as: grace)

      created = Task.find(result.dig("createTask", "task", "id"))
      expect(AuditEvent.where(auditable: created, action: "create").sole.actor).to eq(grace)
      expect(Notification.where(user: heidi, task: created, kind: "task.assigned")).to exist
    end

    it "answers a blank title and an assignee outside the project as errors in the payload, and saves nothing" do
      expect { gql(mutation, variables: { input: project.id.to_s, title: "  ", assignee: outsider.id.to_s }, as: grace) }.not_to change(Task, :count)

      expect(response).to have_http_status(:ok)
      expect(result.dig("createTask", "task")).to be_nil
      expect(result.dig("createTask", "errors").pluck("field")).to contain_exactly("title", "assignee")
    end

    it "is not found in a project the caller cannot see, exactly like one that does not exist" do
      gql(mutation, variables: { input: project.id.to_s, title: "Sneak in" }, as: outsider)
      stranger = errors.first
      gql(mutation, variables: { input: "0", title: "Sneak in" }, as: outsider)

      expect(stranger).to include("message" => "Not found", "extensions" => { "code" => "not_found" })
      expect(errors.first.except("locations", "path")).to eq(stranger.except("locations", "path"))
      expect(Task.where(title: "Sneak in")).to be_empty
    end

    it "is not found in an archived project" do
      project.discard

      gql(mutation, variables: { input: project.id.to_s, title: "Too late" }, as: ada)

      expect(codes).to eq([ "not_found" ])
    end
  end

  describe "updateTask" do
    let(:mutation) do
      <<~GQL
        mutation($id: ID!, $title: String, $lock: Int) {
          updateTask(id: $id, title: $title, lockVersion: $lock) { task { title lockVersion } errors { field message } }
        }
      GQL
    end

    it "changes only what was sent" do
      task.update!(description: "Keep me", priority: :urgent)

      gql(mutation, variables: { id: task.id.to_s, title: "Land on Mars" }, as: grace)

      expect(result.dig("updateTask", "task", "title")).to eq("Land on Mars")
      expect(task.reload).to have_attributes(title: "Land on Mars", description: "Keep me", priority: "urgent")
    end

    it "clears a field that is sent as null, and finishes a task, stamping completed_at as REST does" do
      task.update!(description: "Clear me", due_on: Date.tomorrow, assignee: grace)

      gql(<<~GQL, variables: { id: task.id.to_s })
        mutation($id: ID!) { updateTask(id: $id, description: null, dueOn: null, assigneeId: null, status: DONE) { task { status completedAt } errors { message } } }
      GQL

      expect(result.dig("updateTask", "errors")).to eq([])
      expect(task.reload).to have_attributes(description: nil, due_on: nil, assignee_id: nil, status: "done")
      expect(task.completed_at).to be_present
    end

    it "refuses a stale lockVersion as REST does with 409, and changes nothing" do
      version = task.lock_version
      task.update!(title: "Changed elsewhere")

      gql(mutation, variables: { id: task.id.to_s, title: "Mine", lock: version }, as: grace)

      expect(codes).to eq([ "stale_object" ])
      expect(task.reload.title).to eq("Changed elsewhere")
    end

    it "accepts the current lockVersion and moves it on" do
      gql(mutation, variables: { id: task.id.to_s, title: "Mine", lock: task.lock_version }, as: grace)

      expect(result.dig("updateTask", "task")).to include("title" => "Mine", "lockVersion" => task.lock_version + 1)
    end

    it "is not found for a task in someone else's project, and for one that was deleted" do
      gql(mutation, variables: { id: task.id.to_s, title: "Hijack" }, as: outsider)
      expect(codes).to eq([ "not_found" ])

      task.discard
      gql(mutation, variables: { id: task.id.to_s, title: "Zombie" }, as: ada)
      expect(codes).to eq([ "not_found" ])
      expect(task.reload.title).to eq("Land on the moon")
    end
  end

  describe "deleteTask" do
    let(:mutation) { "mutation($id: ID!) { deleteTask(id: $id) { deletedTaskId errors { message } } }" }

    it "soft-deletes for an administrator or the task's creator, as REST does" do
      gql(mutation, variables: { id: task.id.to_s }, as: ada)
      expect(result.dig("deleteTask", "deletedTaskId")).to eq(task.id.to_s)
      expect(task.reload).to be_discarded

      mine = create(:task, project: project, creator: grace)
      gql(mutation, variables: { id: mine.id.to_s }, as: grace)
      expect(mine.reload).to be_discarded
    end

    it "is forbidden to a member who neither created the task nor administers the project" do
      gql(mutation, variables: { id: task.id.to_s }, as: grace)

      expect(codes).to eq([ "forbidden" ])
      expect(task.reload).not_to be_discarded
    end

    it "is not found for an outsider" do
      gql(mutation, variables: { id: task.id.to_s }, as: outsider)

      expect(codes).to eq([ "not_found" ])
      expect(task.reload).not_to be_discarded
    end
  end

  describe "createComment" do
    let(:mutation) do
      "mutation($task: ID!, $body: String!) { createComment(taskId: $task, body: $body) { comment { body user { name } } errors { field message } } }"
    end

    it "adds the comment as the caller, and tells the people REST tells" do
      task.update!(assignee: heidi)

      expect { gql(mutation, variables: { task: task.id.to_s, body: "On it" }, as: grace) }.to change(Comment, :count).by(1)

      expect(result.dig("createComment", "comment")).to eq("body" => "On it", "user" => { "name" => "Grace" })
      expect(Notification.where(user: heidi, kind: "comment.created")).to exist
    end

    it "answers a blank body as an error in the payload" do
      gql(mutation, variables: { task: task.id.to_s, body: "" }, as: grace)

      expect(result.dig("createComment", "comment")).to be_nil
      expect(result.dig("createComment", "errors").pluck("field")).to eq([ "body" ])
    end

    it "is not found to an outsider" do
      gql(mutation, variables: { task: task.id.to_s, body: "Hello" }, as: outsider)

      expect(codes).to eq([ "not_found" ])
      expect(Comment.count).to eq(0)
    end
  end

  describe "markNotificationRead" do
    let!(:notification) { create(:notification, user: grace, project: project, task: task) }
    let(:mutation) { "mutation($id: ID!, $read: Boolean) { markNotificationRead(id: $id, read: $read) { notification { read readAt } errors { message } } }" }

    it "marks it read, idempotently, and unread again on request" do
      2.times { gql(mutation, variables: { id: notification.id.to_s }, as: grace) }
      expect(result.dig("markNotificationRead", "notification", "read")).to be(true)
      stamped = notification.reload.read_at
      expect(stamped).to be_present

      gql(mutation, variables: { id: notification.id.to_s, read: false }, as: grace)
      expect(notification.reload.read_at).to be_nil
    end

    it "is not found for somebody else's notification" do
      gql(mutation, variables: { id: notification.id.to_s }, as: heidi)

      expect(codes).to eq([ "not_found" ])
      expect(notification.reload).not_to be_read
    end
  end

  describe "authorization" do
    # The scope decides what a caller can find; the policy decides what they may do to it. Today every record a member can find, a member may
    # update, so only a policy that says no tells the two apart: each mutation must ask it, as REST's `authorize` does.
    it "asks the policy for every write, not only the scope" do
      notification = create(:notification, user: grace, project: project, task: task)
      calls = [
        %(createTask(projectId: #{project.id}, title: "x") { errors { message } }),
        "updateTask(id: #{task.id}, title: \"x\") { errors { message } }",
        "deleteTask(id: #{task.id}) { errors { message } }",
        %(createComment(taskId: #{task.id}, body: "x") { errors { message } }),
        "markNotificationRead(id: #{notification.id}) { errors { message } }"
      ]
      allow(Pundit).to receive(:authorize).and_raise(Pundit::NotAuthorizedError)

      calls.each do |call|
        gql("mutation { #{call} }", as: grace)

        expect(codes).to eq([ "forbidden" ]), "#{call} did not ask the policy: #{json}"
      end
      expect([ Task.count, Comment.count, task.reload.title, task.discarded? ]).to eq([ 1, 0, "Land on the moon", false ])
      expect(notification.reload).not_to be_read
    end
  end

  describe "the same input over REST and GraphQL" do
    # Each row: what REST says (status, detail keys) and what GraphQL says (payload error fields or a top-level code) for the same mistake.
    it "fails the same way for the same mistakes" do
      rest = lambda do |attributes|
        api :post, "/api/v1/projects/#{project.id}/tasks", attributes, as: grace
        response.status == 422 ? [ :invalid, error["details"].keys.sort ] : [ :ok ]
      end
      graphql = lambda do |arguments|
        gql("mutation { createTask(projectId: #{project.id}, #{arguments}) { task { id } errors { field } } }", as: grace)
        json["errors"] ? [ :error, codes ] : (result.dig("createTask", "errors").any? ? [ :invalid, result.dig("createTask", "errors").pluck("field").sort ] : [ :ok ])
      end

      expect(graphql.call('title: ""')).to eq(rest.call({ title: "" }))
      expect(graphql.call(%(title: "x", assigneeId: #{outsider.id}))).to eq(rest.call({ title: "x", assignee_id: outsider.id }))
      expect(graphql.call(%(title: "#{'x' * 201}"))).to eq(rest.call({ title: "x" * 201 }))
      expect(graphql.call(%(title: "fine", tagNames: ["a", "a"]))).to eq(rest.call({ title: "fine", tag_names: %w[a a] }))
    end
  end

  describe "limits" do
    it "refuses a request that carries two mutations, and does neither" do
      expect do
        gql(<<~GQL, as: grace)
          mutation { a: createComment(taskId: #{task.id}, body: "one") { errors { message } } b: createComment(taskId: #{task.id}, body: "two") { errors { message } } }
        GQL
      end.not_to change(Comment, :count)

      expect(response).to have_http_status(:ok)
      expect(errors.first["message"]).to include("one mutation")
    end

    it "does not count a mutation's selection set as more mutations" do
      gql(%(mutation { createComment(taskId: #{task.id}, body: "one") { comment { id body user { name } } errors { message } } }), as: grace)

      expect(json["errors"]).to be_nil
    end

    it "is answered 503 read_only while the service is read-only, like the REST write, and nothing is written; queries still work" do
      original = Rails.configuration.x.read_only
      Rails.configuration.x.read_only = true

      expect { gql(%(mutation { createComment(taskId: #{task.id}, body: "late") { errors { message } } }), as: grace) }.not_to change(Comment, :count)
      expect(response).to have_http_status(:service_unavailable)
      expect(error["code"]).to eq("read_only")

      gql("{ me { id } }", as: grace)
      expect(response).to have_http_status(:ok)
    ensure
      Rails.configuration.x.read_only = original
    end

    it "needs a signed-in caller" do
      api :post, "/api/v1/graphql", { query: "mutation { deleteTask(id: 1) { deletedTaskId } }" }

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
