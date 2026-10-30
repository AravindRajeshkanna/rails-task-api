require "swagger_helper"

RSpec.describe "Teams API", type: :request do
  ref = OpenapiSchemas.method(:ref)
  envelope = OpenapiSchemas.method(:envelope)

  let(:owner) { create(:user) }
  let(:Authorization) { auth_headers(owner)["Authorization"] }
  let!(:organization) { create(:organization, owner: owner) }
  let!(:team) { create(:team, organization: organization, name: "Backend") }
  let(:plain_member_headers) { auth_headers(create(:organization_membership, organization: organization).user)["Authorization"] }

  path "/api/v1/organizations/{organization_id}/teams" do
    parameter name: :organization_id, in: :path, type: :integer
    let(:organization_id) { organization.id }

    get "List teams" do
      tags "Teams"
      description "Any member of the organization can list its teams, sorted by name."
      security [ { bearer_auth: [] } ]
      produces "application/json"
      parameter name: :page, in: :query, type: :integer, required: false
      parameter name: :limit, in: :query, type: :integer, required: false

      response "200", "A page of teams" do
        schema envelope.call(ref.call("Team"), list: true)
        run_test! { expect(data.sole).to include("name" => "Backend", "members_count" => 0) }
      end

      response "404", "Not found, or not a member of the organization" do
        schema ref.call("Error")
        let(:organization_id) { create(:organization).id }
        run_test!
      end
    end

    post "Create a team" do
      tags "Teams"
      description "Owners and admins of the organization. Names are unique within it, ignoring case."
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: { type: :object, properties: { name: { type: :string, maxLength: 100 } }, required: [ :name ] }

      response "201", "Created" do
        schema envelope.call(ref.call("Team"))
        let(:body) { { name: "Design" } }
        run_test! { expect(data).to include("name" => "Design", "members_count" => 0) }
      end

      response "403", "Not an owner or admin" do
        schema ref.call("Error")
        let(:body) { { name: "Design" } }
        let(:Authorization) { plain_member_headers }
        run_test!
      end

      response "422", "Name taken or blank" do
        schema ref.call("Error")
        let(:body) { { name: "backend" } }
        run_test!
      end
    end
  end

  path "/api/v1/organizations/{organization_id}/teams/{id}" do
    parameter name: :organization_id, in: :path, type: :integer
    parameter name: :id, in: :path, type: :integer
    let(:organization_id) { organization.id }
    let(:id) { team.id }

    get "Show a team" do
      tags "Teams"
      security [ { bearer_auth: [] } ]
      produces "application/json"

      response "200", "The team" do
        schema envelope.call(ref.call("Team"))
        run_test!
      end
    end

    patch "Rename a team" do
      tags "Teams"
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: { type: :object, properties: { name: { type: :string } }, required: [ :name ] }

      response "200", "Renamed" do
        schema envelope.call(ref.call("Team"))
        let(:body) { { name: "Platform" } }
        run_test! { expect(data["name"]).to eq("Platform") }
      end
    end

    delete "Delete a team" do
      tags "Teams"
      description "Takes the team's access to projects with it."
      security [ { bearer_auth: [] } ]

      response "204", "Deleted" do
        run_test!
      end

      response "403", "Not an owner or admin" do
        schema ref.call("Error")
        let(:Authorization) { plain_member_headers }
        run_test!
      end
    end
  end

  path "/api/v1/organizations/{organization_id}/teams/{team_id}/members" do
    parameter name: :organization_id, in: :path, type: :integer
    parameter name: :team_id, in: :path, type: :integer
    let(:organization_id) { organization.id }
    let(:team_id) { team.id }

    get "List a team's members" do
      tags "Teams"
      security [ { bearer_auth: [] } ]
      produces "application/json"
      parameter name: :page, in: :query, type: :integer, required: false
      parameter name: :limit, in: :query, type: :integer, required: false

      response "200", "A page of members" do
        schema envelope.call(ref.call("TeamMember"), list: true)
        before { create(:team_membership, team: team) }
        run_test! { expect(data.size).to eq(1) }
      end
    end

    post "Add someone to a team" do
      tags "Teams"
      description "By user id; the person must be a member of the organization. A person who is not, and an id that matches " \
                  "nobody, get the same `422`. Owners and admins, and the team's maintainers for plain members: only an owner or admin can add " \
                  "someone as a `maintainer`."
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: {
        type: :object, properties: { user_id: { type: :integer }, role: { type: :string, enum: %w[member maintainer], default: "member" } }, required: [ :user_id ]
      }

      response "201", "Added" do
        schema envelope.call(ref.call("TeamMember"))
        let(:body) { { user_id: create(:organization_membership, organization: organization).user_id } }
        run_test!
      end

      response "422", "Not in the organization, or already in the team" do
        schema ref.call("Error")
        let(:body) { { user_id: create(:user).id } }
        run_test!
      end
    end
  end

  path "/api/v1/organizations/{organization_id}/teams/{team_id}/members/{id}" do
    parameter name: :organization_id, in: :path, type: :integer
    parameter name: :team_id, in: :path, type: :integer
    parameter name: :id, in: :path, type: :integer
    let(:organization_id) { organization.id }
    let(:team_id) { team.id }
    let(:id) { create(:team_membership, team: team).id }

    patch "Change a team member's role" do
      tags "Teams"
      description "Make someone a maintainer of the team, or a plain member again. Owners and admins of the organization only."
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: { type: :object, properties: { role: { type: :string, enum: %w[member maintainer] } }, required: [ :role ] }

      response "200", "Changed" do
        schema envelope.call(ref.call("TeamMember"))
        let(:body) { { role: "maintainer" } }
        run_test! { expect(data["role"]).to eq("maintainer") }
      end

      response "403", "Not an owner or admin" do
        schema ref.call("Error")
        let(:body) { { role: "maintainer" } }
        let(:Authorization) { plain_member_headers }
        run_test!
      end

      response "422", "Not a role" do
        schema ref.call("Error")
        let(:body) { { role: "boss" } }
        run_test!
      end
    end

    delete "Remove someone from a team" do
      tags "Teams"
      description "They lose the access the team gave them to projects. Owners and admins, and a maintainer for a plain member."
      security [ { bearer_auth: [] } ]

      response "204", "Removed" do
        run_test!
      end
    end
  end

  path "/api/v1/projects/{project_id}/teams" do
    parameter name: :project_id, in: :path, type: :integer
    let!(:project) { create(:project, owner: owner, organization: organization) }
    let(:project_id) { project.id }

    get "List the teams with access" do
      tags "Teams"
      security [ { bearer_auth: [] } ]
      produces "application/json"
      parameter name: :page, in: :query, type: :integer, required: false
      parameter name: :limit, in: :query, type: :integer, required: false

      response "200", "A page of grants" do
        schema envelope.call(ref.call("ProjectTeam"), list: true)
        before { create(:project_team, project: project, team: team) }
        run_test! { expect(data.sole["team"]).to eq("id" => team.id, "name" => "Backend") }
      end
    end

    post "Give a team access" do
      tags "Teams"
      description "Project admins grant a team of the project's organization access, as `member` (default) or `admin`; everyone in the " \
                  "team gets that role, added up with their other routes in. A team from anywhere else, and an id that matches no " \
                  "team, get the same `422`."
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: {
        type: :object, properties: { team_id: { type: :integer }, role: { type: :string, enum: %w[member admin], default: "member" } }, required: [ :team_id ]
      }

      response "201", "Granted" do
        schema envelope.call(ref.call("ProjectTeam"))
        let(:body) { { team_id: team.id, role: "admin" } }
        run_test! { expect(data["role"]).to eq("admin") }
      end

      response "422", "Not a team of the project's organization, or already granted" do
        schema ref.call("Error")
        let(:body) { { team_id: create(:team).id } }
        run_test!
      end
    end
  end

  path "/api/v1/projects/{project_id}/teams/{id}" do
    parameter name: :project_id, in: :path, type: :integer
    parameter name: :id, in: :path, type: :integer
    let!(:project) { create(:project, owner: owner, organization: organization) }
    let!(:grant) { create(:project_team, project: project, team: team) }
    let(:project_id) { project.id }
    let(:id) { grant.id }

    patch "Change a team's role in a project" do
      tags "Teams"
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: { type: :object, properties: { role: { type: :string, enum: %w[member admin] } }, required: [ :role ] }

      response "200", "Updated" do
        schema envelope.call(ref.call("ProjectTeam"))
        let(:body) { { role: "admin" } }
        run_test! { expect(data["role"]).to eq("admin") }
      end
    end

    delete "Withdraw a team's access" do
      tags "Teams"
      security [ { bearer_auth: [] } ]

      response "204", "Withdrawn" do
        run_test!
      end
    end
  end
end
