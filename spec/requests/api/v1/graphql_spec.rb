require "rails_helper"

RSpec.describe "GraphQL" do
  let(:ada) { create(:user, name: "Ada", email_address: "ada@example.com") }
  let(:grace) { create(:user, name: "Grace", email_address: "grace@example.com") }
  let(:outsider) { create(:user) }
  let!(:project) { create(:project, owner: ada, name: "Apollo") }

  before { create(:membership, project: project, user: grace) }

  def gql(query, variables: nil, as: ada, operation_name: nil)
    api :post, "/api/v1/graphql", { query: query, variables: variables, operationName: operation_name }.compact, as: as
  end

  def result = json.fetch("data")
  def errors = json.fetch("errors")

  describe "reading" do
    it "returns the signed-in person, with their own email address" do
      gql("{ me { id name emailAddress } }")

      expect(response).to have_http_status(:ok)
      expect(result["me"]).to eq("id" => ada.id.to_s, "name" => "Ada", "emailAddress" => "ada@example.com")
    end

    it "fetches a project with its tasks, their people, tags and comments in one request" do
      task = create(:task, project: project, creator: ada, assignee: grace, title: "Land on the moon", priority: :urgent, tag_names: %w[bug api])
      create(:comment, task: task, user: grace, body: "On it")

      gql(<<~GQL)
        {
          projects(first: 5) {
            nodes {
              id name role owner { name }
              tasks(first: 5) {
                nodes {
                  title status priority overdue tags creator { name } assignee { name } project { name }
                  comments(first: 5) { nodes { body user { name } } }
                }
              }
            }
          }
        }
      GQL

      expect(response).to have_http_status(:ok)
      fetched = result.dig("projects", "nodes").sole
      expect(fetched).to include("id" => project.id.to_s, "name" => "Apollo", "role" => "admin", "owner" => { "name" => "Ada" })
      expect(fetched.dig("tasks", "nodes").sole).to include(
        "title" => "Land on the moon", "status" => "TODO", "priority" => "URGENT", "overdue" => false, "tags" => %w[api bug],
        "creator" => { "name" => "Ada" }, "assignee" => { "name" => "Grace" }, "project" => { "name" => "Apollo" },
        "comments" => { "nodes" => [ { "body" => "On it", "user" => { "name" => "Grace" } } ] }
      )
    end

    it "does not run a query per row: the number of queries does not grow with the number of tasks" do
      query = "{ projects(first: 5) { nodes { tasks(first: 20) { nodes { title creator { name } assignee { name } tags project { name } } } } } }"
      create_list(:task, 2, project: project, assignee: grace, tag_names: %w[a])
      gql(query) # warm: the first request loads schema-level caches
      few = count_queries { gql(query) }

      create_list(:task, 10, project: project, assignee: grace, tag_names: %w[a b])
      many = count_queries { gql(query) }

      expect(response).to have_http_status(:ok)
      expect(json["errors"]).to be_nil
      expect(many).to eq(few)
    end

    it "pages with cursors" do
      create_list(:task, 5, project: project)

      gql("query($after: String) { project(id: #{project.id}) { tasks(first: 2, after: $after) { nodes { id } pageInfo { hasNextPage endCursor } } } }")
      first_page = result.dig("project", "tasks")
      expect(first_page["nodes"].size).to eq(2)
      expect(first_page.dig("pageInfo", "hasNextPage")).to be(true)

      gql("query($after: String) { project(id: #{project.id}) { tasks(first: 2, after: $after) { nodes { id } } } }", variables: { after: first_page.dig("pageInfo", "endCursor") })
      expect(result.dig("project", "tasks", "nodes").pluck("id") & first_page["nodes"].pluck("id")).to be_empty
    end

    it "filters and sorts a project's tasks like REST does" do
      create(:task, project: project, title: "Invoice fix", status: :done, priority: :high)
      create(:task, project: project, title: "Invoice template", priority: :low)
      create(:task, project: project, title: "Write docs", priority: :high)

      gql("{ project(id: #{project.id}) { tasks(first: 10, status: [DONE]) { nodes { title } } } }")
      expect(result.dig("project", "tasks", "nodes").pluck("title")).to eq([ "Invoice fix" ])

      gql("{ project(id: #{project.id}) { tasks(first: 10, search: \"invoice\", sort: \"title\") { nodes { title } } } }")
      expect(result.dig("project", "tasks", "nodes").pluck("title")).to eq([ "Invoice fix", "Invoice template" ])

      gql("{ project(id: #{project.id}) { tasks(first: 10, priority: [HIGH], assignee: \"unassigned\") { nodes { title } } } }")
      expect(result.dig("project", "tasks", "nodes").pluck("title")).to contain_exactly("Invoice fix", "Write docs")
    end

    it "searches across projects, best match first, with highlights" do
      other = create(:project, owner: ada, name: "Gemini")
      create(:task, project: project, title: "Quarterly review", description: "Check the invoice totals")
      create(:task, project: other, title: "Invoice template", description: nil)

      gql('{ search(query: "invoice", first: 5) { nodes { rank titleHighlight descriptionHighlight task { title project { name } } } } }')

      nodes = result.dig("search", "nodes")
      expect(nodes.map { _1.dig("task", "title") }).to eq([ "Invoice template", "Quarterly review" ])
      expect(nodes.first).to include("titleHighlight" => "«Invoice» template", "descriptionHighlight" => nil)
      expect(nodes.first["rank"]).to be > nodes.last["rank"]
      expect(nodes.last["descriptionHighlight"]).to include("«invoice»")
    end

    it "reads the inbox and counts what is unread" do
      task = create(:task, project: project)
      create(:notification, user: grace, project: project, task: task, kind: "comment.created", data: { task_title: "T" })
      create(:notification, :read, user: grace, project: project, task: task)

      gql("{ unreadNotificationsCount notifications(first: 10, unread: true) { nodes { kind read data } } }", as: grace)

      expect(result["unreadNotificationsCount"]).to eq(1)
      expect(result.dig("notifications", "nodes")).to eq([ { "kind" => "comment.created", "read" => false, "data" => { "task_title" => "T" } } ])
    end
  end

  describe "who can see what" do
    it "shows an outsider nothing: their projects list is empty, and another's project and task are null" do
      task = create(:task, project: project)

      gql("{ projects(first: 5) { nodes { id } } p: project(id: #{project.id}) { name } t: task(id: #{task.id}) { title } }", as: outsider)

      expect(response).to have_http_status(:ok)
      expect(result).to eq("projects" => { "nodes" => [] }, "p" => nil, "t" => nil)
      expect(json["errors"]).to be_nil # nothing says it exists
    end

    it "answers exactly the same for a project that does not exist as for one you cannot see" do
      gql("{ a: project(id: #{project.id}) { name } b: project(id: 0) { name } }", as: outsider)

      expect(result).to eq("a" => nil, "b" => nil)
    end

    it "never returns discarded tasks or archived projects" do
      create(:task, :discarded, project: project, title: "Gone")
      archived = create(:project, owner: ada, discarded_at: 1.day.ago)
      kept = create(:task, project: project, title: "Here")

      gql("{ projects(first: 10) { nodes { name } } project(id: #{project.id}) { tasks(first: 10) { nodes { title } } } archived: project(id: #{archived.id}) { name } }")

      expect(result["projects"]["nodes"].pluck("name")).to eq([ "Apollo" ])
      expect(result.dig("project", "tasks", "nodes").pluck("title")).to eq([ kept.title ])
      expect(result["archived"]).to be_nil
    end

    it "follows teams and organizations exactly as REST does" do
      organization = create(:organization)
      boss = create(:organization_membership, :owner, organization: organization).user
      worker = create(:organization_membership, organization: organization).user
      granted = create(:project, owner: boss, organization: organization, name: "Granted")
      create(:project, owner: boss, organization: organization, name: "Not granted")
      grant = create(:project_team, project: granted, team: create(:team, organization: organization))
      create(:team_membership, team: grant.team, user: worker)

      gql("{ projects(first: 10) { nodes { name role } } }", as: worker)
      expect(result["projects"]["nodes"]).to eq([ { "name" => "Granted", "role" => "member" } ])

      gql("{ projects(first: 10) { nodes { name role } } }", as: boss)
      expect(result["projects"]["nodes"].pluck("name")).to contain_exactly("Granted", "Not granted")
    end

    it "does not show comments of a task in a project you cannot see, even by guessing the id" do
      task = create(:task, project: project)
      create(:comment, task: task, user: ada, body: "Secret")

      gql("{ task(id: #{task.id}) { comments(first: 5) { nodes { body } } } }", as: outsider)

      expect(result["task"]).to be_nil
      expect(response.body).not_to include("Secret")
    end

    it "does not expose other people's email addresses, because the field is not there" do
      gql("{ project(id: #{project.id}) { owner { emailAddress } } }")

      expect(errors.first["message"]).to include("doesn't exist on type 'User'")
    end

    it "requires sign-in" do
      gql("{ me { id } }", as: nil)

      expect(response).to have_http_status(:unauthorized)
      expect(error["code"]).to eq("unauthenticated")
    end
  end

  describe "limits" do
    it "caps a page at 100 and refuses a query whose cost is too high" do
      gql("{ projects(first: 500) { nodes { id } } }")
      expect(result["projects"]["nodes"].size).to be <= 100

      expensive = "{ projects(first: 100) { nodes { tasks(first: 100) { nodes { comments(first: 100) { nodes { body } } } } } } }"
      gql(expensive)
      expect(response).to have_http_status(:ok)
      expect(errors.first["message"]).to match(/complexity/i)
      expect(json["data"]).to be_nil
    end

    it "refuses a query nested too deeply" do
      deep = "{ project(id: 1) { tasks(first: 1) { nodes { project { tasks(first: 1) { nodes { project { tasks(first: 1) { nodes { project { name } } } } } } } } } } }"

      gql(deep)

      expect(errors.first["message"]).to match(/depth/i)
    end

    it "refuses an oversized query before parsing it, and a batch of queries" do
      gql("{ me { id } } #{'#' * Api::V1::GraphqlController::MAX_QUERY_BYTES}")
      expect(response).to have_http_status(:bad_request)
      expect(error).to include("code" => "invalid_parameter", "details" => { "parameter" => "query" })

      api :post, "/api/v1/graphql", [ { query: "{ me { id } }" }, { query: "{ me { id } }" } ], as: ada
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "errors" do
    it "reports a bad filter as an error with a code, not a 500, and still answers the rest" do
      gql("{ me { name } project(id: #{project.id}) { tasks(first: 1, sort: \"nonsense\") { nodes { id } } } }")

      expect(response).to have_http_status(:ok)
      expect(errors.first["extensions"]).to include("code" => "invalid_parameter", "parameter" => "sort")
      expect(result["me"]).to eq("name" => "Ada")
    end

    it "reports invalid GraphQL as errors with a 200, and a missing query as the usual 400" do
      gql("{ me { nonsense } }")
      expect(response).to have_http_status(:ok)
      expect(errors.first["message"]).to include("nonsense")

      api :post, "/api/v1/graphql", {}, as: ada
      expect(response).to have_http_status(:bad_request)
      expect(error["code"]).to eq("parameter_missing")
    end

    it "takes variables as an object or as a JSON string, and an operation name" do
      gql("query Mine($id: ID!) { project(id: $id) { name } } query Other { me { name } }", variables: { id: project.id.to_s }, operation_name: "Mine")
      expect(result["project"]).to eq("name" => "Apollo")

      api :post, "/api/v1/graphql", { query: "query($id: ID!) { project(id: $id) { name } }", variables: { id: project.id.to_s }.to_json }, as: ada
      expect(result["project"]).to eq("name" => "Apollo")

      api :post, "/api/v1/graphql", { query: "{ me { id } }", variables: "{nope" }, as: ada
      expect(response).to have_http_status(:bad_request)
      expect(error["details"]).to eq("parameter" => "variables")
    end

    it "serves the schema to a signed-in client that asks for it" do
      gql("{ __schema { queryType { name } } __type(name: \"Task\") { fields { name } } }")

      expect(result.dig("__schema", "queryType", "name")).to eq("Query")
      expect(result.dig("__type", "fields").pluck("name")).to include("title", "comments")
    end
  end

  describe "the committed schema" do
    it "matches the code (regenerate with bin/rails graphql:schema:dump)" do
      expect(File.read(Rails.root.join("docs/graphql/schema.graphql"))).to eq(TaskApiSchema.to_definition)
    end
  end
end
