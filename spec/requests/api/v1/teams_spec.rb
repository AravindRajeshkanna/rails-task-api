require "rails_helper"

RSpec.describe "Teams" do
  let(:ada) { create(:user, name: "Ada") }
  let(:grace) { create(:user, name: "Grace") }
  let(:linus) { create(:user, name: "Linus") }
  let(:outsider) { create(:user) }
  let!(:organization) { create(:organization, owner: ada) }
  let(:org_path) { "/api/v1/organizations/#{organization.id}" }

  before do
    create(:organization_membership, organization: organization, user: grace)
    create(:organization_membership, organization: organization, user: linus)
  end

  def create_team(name = "Backend", as: ada)
    api :post, "#{org_path}/teams", { name: name }, as: as
    data["id"] if response.status == 201
  end

  describe "the whole lifecycle" do
    it "builds a team, gives it a project, and lets its members work there until they leave" do
      team_id = create_team
      expect(response).to have_http_status(:created)
      expect(data).to include("name" => "Backend", "organization_id" => organization.id, "members_count" => 0)

      api :post, "#{org_path}/teams/#{team_id}/members", { user_id: grace.id }, as: ada
      expect(response).to have_http_status(:created)
      expect(data["user"]).to eq("id" => grace.id, "name" => "Grace")
      grace_membership_id = data["id"]

      api :get, "#{org_path}/teams/#{team_id}", as: ada
      expect(data["members_count"]).to eq(1)

      # Linus owns a project in the organization; Grace is in no way a member of it yet.
      api :post, "/api/v1/projects", { name: "Relaunch", organization_id: organization.id }, as: linus
      project_id = data.fetch("id")
      api :get, "/api/v1/projects/#{project_id}", as: grace
      expect(response).to have_http_status(:not_found)

      # Granting the team gives Grace access, as member.
      api :post, "/api/v1/projects/#{project_id}/teams", { team_id: team_id }, as: linus
      expect(response).to have_http_status(:created)
      expect(data).to include("role" => "member", "team" => { "id" => team_id, "name" => "Backend" })
      grant_id = data["id"]

      api :get, "/api/v1/projects/#{project_id}", as: grace
      expect(response).to have_http_status(:ok)
      expect(data["role"]).to eq("member")
      api :get, "/api/v1/projects", as: grace
      expect(data.pluck("id")).to include(project_id)
      api :post, "/api/v1/projects/#{project_id}/tasks", { title: "From the team" }, as: grace
      expect(response).to have_http_status(:created)
      task_id = data["id"]
      api :patch, "/api/v1/projects/#{project_id}", { name: "Hijacked" }, as: grace
      expect(response).to have_http_status(:forbidden) # a member, not an admin

      # Team members can be given work, though they are not project members.
      api :patch, "/api/v1/tasks/#{task_id}", { assignee_id: grace.id }, as: linus
      expect(response).to have_http_status(:ok)
      expect(data["assignee"]).to include("id" => grace.id)

      # Raising the grant to admin raises everyone in the team.
      api :patch, "/api/v1/projects/#{project_id}/teams/#{grant_id}", { role: "admin" }, as: linus
      expect(response).to have_http_status(:ok)
      api :patch, "/api/v1/projects/#{project_id}", { name: "Relaunch 2" }, as: grace
      expect(response).to have_http_status(:ok)

      # Taking Grace out of the team takes her access with it.
      api :delete, "#{org_path}/teams/#{team_id}/members/#{grace_membership_id}", as: ada
      expect(response).to have_http_status(:no_content)
      api :get, "/api/v1/projects/#{project_id}", as: grace
      expect(response).to have_http_status(:not_found)
    end

    it "ends the access when the grant is withdrawn or the team is deleted" do
      team_id = create_team
      api :post, "#{org_path}/teams/#{team_id}/members", { user_id: grace.id }, as: ada
      project = create(:project, owner: linus, organization: organization)
      api :post, "/api/v1/projects/#{project.id}/teams", { team_id: team_id }, as: linus
      grant_id = data["id"]

      api :delete, "/api/v1/projects/#{project.id}/teams/#{grant_id}", as: linus
      expect(response).to have_http_status(:no_content)
      api :get, "/api/v1/projects/#{project.id}", as: grace
      expect(response).to have_http_status(:not_found)

      api :post, "/api/v1/projects/#{project.id}/teams", { team_id: team_id }, as: linus
      api :delete, "#{org_path}/teams/#{team_id}", as: ada
      expect(response).to have_http_status(:no_content)
      api :get, "/api/v1/projects/#{project.id}", as: grace
      expect(response).to have_http_status(:not_found)
      expect(ProjectTeam.count).to eq(0)
    end

    it "takes someone out of every team when they leave the organization" do
      team_id = create_team
      api :post, "#{org_path}/teams/#{team_id}/members", { user_id: linus.id }, as: ada
      linus_role = OrganizationMembership.find_by!(organization: organization, user: linus)

      api :delete, "#{org_path}/members/#{linus_role.id}", as: ada

      expect(response).to have_http_status(:no_content)
      expect(TeamMembership.where(user: linus)).not_to exist
    end
  end

  describe "teams" do
    it "lists with member counts, sorted by name, to any member of the organization" do
      backend = create_team("Backend")
      create_team("Alpha")
      api :post, "#{org_path}/teams/#{backend}/members", { user_id: grace.id }, as: ada

      api :get, "#{org_path}/teams", as: linus

      expect(data.pluck("name", "members_count")).to eq([ [ "Alpha", 0 ], [ "Backend", 1 ] ])
    end

    it "renames, and refuses a duplicate name in the organization, in any case" do
      team_id = create_team("Backend")
      create_team("Design")

      api :patch, "#{org_path}/teams/#{team_id}", { name: "Platform" }, as: ada
      expect(data["name"]).to eq("Platform")

      create_team("platform")
      expect(response).to have_http_status(:unprocessable_content)
      expect(error["details"]["name"]).to be_present
      create_team(" ")
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "is managed by owners and admins only" do
      create_team("Backend", as: linus)
      expect(response).to have_http_status(:forbidden)

      team_id = create_team
      api :patch, "#{org_path}/teams/#{team_id}", { name: "Other" }, as: linus
      expect(response).to have_http_status(:forbidden)
      api :delete, "#{org_path}/teams/#{team_id}", as: linus
      expect(response).to have_http_status(:forbidden)

      OrganizationMembership.find_by!(organization: organization, user: grace).update!(role: "admin")
      create_team("Design", as: grace)
      expect(response).to have_http_status(:created)
    end

    it "is invisible to outsiders, and another organization's team is a 404 under this one" do
      team_id = create_team
      elsewhere = create(:team)

      api :get, "#{org_path}/teams", as: outsider
      expect(response).to have_http_status(:not_found)
      api :get, "#{org_path}/teams/#{elsewhere.id}", as: ada
      expect(response).to have_http_status(:not_found)
      api :get, "#{org_path}/teams/#{team_id}"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "team members" do
    let!(:team_id) { create_team }

    it "takes organization members only, and says the same thing for a non-member as for nobody" do
      api :post, "#{org_path}/teams/#{team_id}/members", { user_id: outsider.id }, as: ada
      registered = [ response.status, error["code"], error["details"] ]
      api :post, "#{org_path}/teams/#{team_id}/members", { user_id: 0 }, as: ada
      unknown = [ response.status, error["code"], error["details"] ]

      expect(registered).to eq([ 422, "validation_failed", { "user" => [ "must be a member of the team's organization" ] } ])
      expect(unknown).to eq(registered)
      expect(TeamMembership.count).to eq(0)
    end

    it "adds a person once" do
      api :post, "#{org_path}/teams/#{team_id}/members", { user_id: grace.id }, as: ada
      api :post, "#{org_path}/teams/#{team_id}/members", { user_id: grace.id }, as: ada

      expect(response).to have_http_status(:unprocessable_content)
      expect(error["details"]["user_id"]).to include("is already in this team")
    end

    it "lists members to the organization and is managed by its administrators" do
      api :post, "#{org_path}/teams/#{team_id}/members", { user_id: grace.id }, as: ada

      api :get, "#{org_path}/teams/#{team_id}/members", as: linus
      expect(data.map { _1.dig("user", "name") }).to eq([ "Grace" ])

      api :post, "#{org_path}/teams/#{team_id}/members", { user_id: linus.id }, as: linus
      expect(response).to have_http_status(:forbidden)
      api :delete, "#{org_path}/teams/#{team_id}/members/#{TeamMembership.first.id}", as: linus
      expect(response).to have_http_status(:forbidden)
      api :get, "#{org_path}/teams/#{team_id}/members", as: outsider
      expect(response).to have_http_status(:not_found)
    end

    it "requires a user_id" do
      api :post, "#{org_path}/teams/#{team_id}/members", {}, as: ada

      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "a team's access to a project" do
    let!(:team_id) { create_team }
    let!(:project) { create(:project, owner: linus, organization: organization) }
    let(:path) { "/api/v1/projects/#{project.id}/teams" }

    it "takes a team of the project's organization only, and says the same thing for another organization's as for none" do
      foreign = create(:team)

      api :post, path, { team_id: foreign.id }, as: linus
      other = [ response.status, error["details"] ]
      api :post, path, { team_id: 0 }, as: linus
      none = [ response.status, error["details"] ]

      expect(other).to eq([ 422, { "team" => [ "must belong to the project's organization" ] } ])
      expect(none).to eq(other)
    end

    it "is not available for a personal project" do
      personal = create(:project, owner: linus)

      api :post, "/api/v1/projects/#{personal.id}/teams", { team_id: team_id }, as: linus

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "grants a team once, with a valid role" do
      api :post, path, { team_id: team_id, role: "emperor" }, as: linus
      expect(response).to have_http_status(:unprocessable_content)

      api :post, path, { team_id: team_id, role: "admin" }, as: linus
      expect(response).to have_http_status(:created)
      api :post, path, { team_id: team_id }, as: linus
      expect(response).to have_http_status(:unprocessable_content)
      expect(error["details"]["team_id"]).to include("already has access to this project")
    end

    it "lists the teams with access to anyone in the project, and changes only for its admins" do
      api :post, path, { team_id: team_id }, as: linus
      create(:membership, project: project, user: grace)

      api :get, path, as: grace
      expect(response).to have_http_status(:ok)
      expect(data.sole["team"]["name"]).to eq("Backend")

      api :post, path, { team_id: create_team("Design") }, as: grace
      expect(response).to have_http_status(:forbidden)
      api :delete, "#{path}/#{ProjectTeam.first.id}", as: grace
      expect(response).to have_http_status(:forbidden)
      api :get, path, as: outsider
      expect(response).to have_http_status(:not_found)
    end

    it "lets organization admins manage it without being in the project" do
      api :post, path, { team_id: team_id }, as: ada

      expect(response).to have_http_status(:created)
    end

    it "does not allow granting an archived project" do
      project.update!(discarded_at: Time.current)

      api :post, path, { team_id: team_id }, as: linus

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "who can be given work" do
    it "includes team members, not people with no route into the project" do
      team_id = create_team
      api :post, "#{org_path}/teams/#{team_id}/members", { user_id: grace.id }, as: ada
      project = create(:project, owner: linus, organization: organization)
      create(:project_team, project: project, team: Team.find(team_id))
      task = create(:task, project: project, creator: linus)

      api :patch, "/api/v1/tasks/#{task.id}", { assignee_id: grace.id }, as: linus
      expect(response).to have_http_status(:ok)

      api :patch, "/api/v1/tasks/#{task.id}", { assignee_id: ada.id }, as: linus # an organization owner, not a participant
      expect(response).to have_http_status(:unprocessable_content)
      expect(project.participants).to contain_exactly(linus, grace)
    end
  end
end
