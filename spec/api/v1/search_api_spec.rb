require "swagger_helper"

RSpec.describe "Search API", type: :request do
  ref = OpenapiSchemas.method(:ref)
  envelope = OpenapiSchemas.method(:envelope)

  let(:owner) { create(:user) }
  let(:Authorization) { auth_headers(owner)["Authorization"] }
  let!(:project) { create(:project, owner: owner, name: "Alpha") }

  path "/api/v1/search" do
    get "Search tasks across my projects" do
      tags "Search"
      description "Full-text search of task titles and descriptions in every project the caller can see (including through a team or an " \
                  "organization), best match first. Words are stemmed (`deploying` finds `deployed`); `\"quoted phrases\"`, `or` and " \
                  "`-excluded` work; any text is safe. Deleted tasks and archived projects never match. Inside one project, use " \
                  "`search` on its task list."
      security [ { bearer_auth: [] } ]
      produces "application/json"
      parameter name: :q, in: :query, type: :string, required: true, description: "What to look for, at most 200 characters"
      parameter name: :project_id, in: :query, type: :integer, required: false, description: "Only this project"
      parameter name: :page, in: :query, type: :integer, required: false
      parameter name: :limit, in: :query, type: :integer, required: false

      response "200", "A page of matches" do
        schema envelope.call(ref.call("SearchResult"), list: true)
        let(:q) { "invoice" }
        before { create(:task, project: project, title: "Fix invoice rounding", description: "The billing module") }
        run_test! { expect(data.sole).to include("title" => "Fix invoice rounding", "project" => { "id" => project.id, "name" => "Alpha" }) }
      end

      response "400", "q is missing or longer than 200 characters" do
        schema ref.call("Error")
        let(:q) { "x" * 201 }
        run_test!
      end

      response "401", "Missing or invalid token" do
        schema ref.call("Error")
        let(:q) { "invoice" }
        let(:Authorization) { nil }
        run_test!
      end
    end
  end
end
