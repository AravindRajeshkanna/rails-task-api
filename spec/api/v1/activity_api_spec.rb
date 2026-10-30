require "swagger_helper"

RSpec.describe "Activity API", type: :request do
  ref = OpenapiSchemas.method(:ref)
  OpenapiSchemas.method(:envelope)

  let(:user) { create(:user) }
  let(:Authorization) { auth_headers(user)["Authorization"] }
  let!(:project) { create(:project, owner: user) }

  path "/api/v1/activity" do
    get "Activity feed" do
      tags "Activity"
      description "Everything that happened in the projects you belong to (projects, tasks and membership changes), newest " \
                  "first. This is the member's view of the audit log; admins can also read a single project's full log at " \
                  "`/projects/{id}/audit_events`. Deleted projects contribute nothing until restored."
      security [ { bearer_auth: [] } ]
      produces "application/json"
      parameter name: :project_id, in: :query, type: :integer, required: false, description: "Only this project (ignored if you are not in it)"
      parameter name: :type, in: :query, type: :string, required: false, description: "Comma-separated: Project, Task, Membership, ProjectTeam"
      parameter name: :page, in: :query, type: :integer, required: false
      parameter name: :limit, in: :query, type: :integer, required: false
      parameter name: :cursor, in: :query, type: :string, required: false, allowEmptyValue: true,
                description: "Switches to keyset pagination, which costs the same however long the history is and has no total (`meta` is `{limit, next_cursor, has_more}`). Send it empty for the first page, then `meta.next_cursor` of the previous response (with the same filters). An invalid cursor is a 400. Replaces `page`."

      response "200", "A page of events (`meta` has `page`, `count`...; with `cursor`, `next_cursor` and `has_more` and no total)" do
        schema OpenapiSchemas.listing(ref.call("Activity"))
        before { create(:task, project: project, creator: user) }
        run_test! { expect(data.pluck("auditable_type")).to include("Task", "Project") }
      end

      response "400", "Unknown `type`" do
        schema ref.call("Error")
        let(:type) { "Webhook" }
        run_test!
      end

      response "401", "Missing or invalid token" do
        schema ref.call("Error")
        let(:Authorization) { nil }
        run_test!
      end
    end
  end
end
