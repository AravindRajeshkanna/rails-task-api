require "rails_helper"

RSpec.describe "Projects" do
  let(:owner) { create(:user) }
  let(:project) { create(:project, owner: owner) }
  let(:member) { create(:membership, project:).user }
  let(:admin) { create(:membership, :admin, project:).user }
  let(:outsider) { create(:user) }

  describe "GET /api/v1/projects" do
    it "lists only projects the user belongs to, newest first, with the user's role" do
      older = create(:project, owner:, created_at: 2.days.ago)
      newer = create(:project, owner:)
      joined = create(:project)
      create(:membership, project: joined, user: owner)
      create(:project) # someone else's
      create(:project, :discarded, owner:)

      api :get, "/api/v1/projects", as: owner

      expect(response).to have_http_status(:ok)
      expect(data.map { _1["id"] }).to eq([ joined.id, newer.id, older.id ].sort_by { |id| -Project.find(id).created_at.to_f })
      expect(data.to_h { [ _1["id"], _1["role"] ] }).to eq(older.id => "admin", newer.id => "admin", joined.id => "member")
      expect(data.first["owner"]).to include("id", "name")
      expect(data.first["owner"]).not_to have_key("email_address")
    end

    it "paginates with meta and RFC 8288 headers" do
      create_list(:project, 3, owner:)

      api :get, "/api/v1/projects", { limit: 2, page: 2 }, as: owner

      expect(data.size).to eq(1)
      expect(meta).to include("page" => 2, "limit" => 2, "count" => 3, "pages" => 2, "next" => nil, "previous" => 1)
      expect(response.headers).to include("Total-Count" => "3", "Total-Pages" => "2", "Current-Page" => "2", "Page-Limit" => "2")
      expect(response.headers["Link"]).to include('rel="prev"')
    end

    it "caps the page size at 100" do
      api :get, "/api/v1/projects", { limit: 5_000 }, as: owner

      expect(meta["limit"]).to eq(100)
    end

    it "returns an empty page past the end" do
      api :get, "/api/v1/projects", { page: 99 }, as: owner

      expect(response).to have_http_status(:ok)
      expect(data).to eq([])
    end
  end

  describe "POST /api/v1/projects" do
    it "creates a project owned by the user, who becomes its admin" do
      api :post, "/api/v1/projects", { name: "Launch", description: "Q4" }, as: owner

      expect(response).to have_http_status(:created)
      expect(data).to include("name" => "Launch", "role" => "admin", "owner" => include("id" => owner.id))
      expect(data["stats"]).to eq("todo" => 0, "in_progress" => 0, "done" => 0, "overdue" => 0)
    end

    it "validates the name" do
      api :post, "/api/v1/projects", { name: "" }, as: owner

      expect(response).to have_http_status(:unprocessable_content)
      expect(error["details"]).to eq("name" => [ "can't be blank" ])
    end

    it "cannot assign ownership to someone else" do
      api :post, "/api/v1/projects", { name: "Sneaky", owner_id: outsider.id }, as: owner

      expect(Project.find_by!(name: "Sneaky").owner).to eq(owner)
    end
  end

  describe "GET /api/v1/projects/:id" do
    it "shows a project with task stats to members" do
      create(:task, project:)
      create(:task, :done, project:)

      api :get, "/api/v1/projects/#{project.id}", as: member

      expect(response).to have_http_status(:ok)
      expect(data).to include("id" => project.id, "role" => "member")
      expect(data["stats"]).to include("todo" => 1, "done" => 1)
    end

    it "hides the project's existence from non-members with a 404" do
      api :get, "/api/v1/projects/#{project.id}", as: outsider

      expect(response).to have_http_status(:not_found)
      expect(error).to include("code" => "not_found")
    end

    it "404s for discarded projects" do
      project.discard

      api :get, "/api/v1/projects/#{project.id}", as: owner

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /api/v1/projects/:id" do
    it "lets admins update" do
      api :patch, "/api/v1/projects/#{project.id}", { name: "Renamed" }, as: admin

      expect(response).to have_http_status(:ok)
      expect(project.reload.name).to eq("Renamed")
    end

    it "forbids plain members" do
      api :patch, "/api/v1/projects/#{project.id}", { name: "Renamed" }, as: member

      expect(response).to have_http_status(:forbidden)
      expect(error["code"]).to eq("forbidden")
      expect(project.reload.name).not_to eq("Renamed")
    end
  end

  describe "DELETE /api/v1/projects/:id and restore" do
    it "soft-deletes for the owner, and restores" do
      api :delete, "/api/v1/projects/#{project.id}", as: owner
      expect(response).to have_http_status(:no_content)
      expect(project.reload).to be_discarded

      api :get, "/api/v1/projects", as: owner
      expect(data).to be_empty

      api :post, "/api/v1/projects/#{project.id}/restore", as: owner
      expect(response).to have_http_status(:ok)
      expect(project.reload).to be_kept
    end

    it "forbids admins who are not the owner" do
      api :delete, "/api/v1/projects/#{project.id}", as: admin

      expect(response).to have_http_status(:forbidden)
      expect(project.reload).to be_kept
    end

    it "only lets the owner restore" do
      project.discard

      api :post, "/api/v1/projects/#{project.id}/restore", as: admin
      expect(response).to have_http_status(:forbidden)

      api :post, "/api/v1/projects/#{project.id}/restore", as: outsider
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "memberships" do
    let!(:newcomer) { create(:user, email_address: "newcomer@example.com") }

    it "lets members list the team" do
      member
      api :get, "/api/v1/projects/#{project.id}/memberships", as: member

      expect(response).to have_http_status(:ok)
      expect(data.map { _1.dig("user", "id") }).to contain_exactly(owner.id, member.id)
      expect(data.find { _1.dig("user", "id") == owner.id }["role"]).to eq("admin")
    end

    it "lets admins add an existing user by email" do
      api :post, "/api/v1/projects/#{project.id}/memberships", { email_address: " Newcomer@Example.com ", role: "member" }, as: admin

      expect(response).to have_http_status(:created)
      expect(data).to include("role" => "member", "user" => include("id" => newcomer.id))
      expect(project.members).to include(newcomer)
    end

    it "404s for an unknown email, 422s for a duplicate or invalid role" do
      api :post, "/api/v1/projects/#{project.id}/memberships", { email_address: "ghost@example.com" }, as: admin
      expect(response).to have_http_status(:not_found)

      api :post, "/api/v1/projects/#{project.id}/memberships", { email_address: member.email_address }, as: admin
      expect(response).to have_http_status(:unprocessable_content)

      api :post, "/api/v1/projects/#{project.id}/memberships", { email_address: newcomer.email_address, role: "emperor" }, as: admin
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "throttles adding people, so the endpoint cannot be used to probe addresses at speed" do
      allow(Rails.cache).to receive(:increment).and_return(61)

      api :post, "/api/v1/projects/#{project.id}/memberships", { email_address: newcomer.email_address }, as: admin

      expect(response).to have_http_status(:too_many_requests)
      expect(project.members).not_to include(newcomer)
    end

    it "forbids members from adding people" do
      api :post, "/api/v1/projects/#{project.id}/memberships", { email_address: newcomer.email_address }, as: member

      expect(response).to have_http_status(:forbidden)
    end

    it "lets admins change roles but never demote the owner" do
      membership = project.memberships.find_by!(user: member)
      owner_membership = project.memberships.find_by!(user: owner)

      api :patch, "/api/v1/memberships/#{membership.id}", { role: "admin" }, as: admin
      expect(response).to have_http_status(:ok)
      expect(membership.reload).to be_admin

      api :patch, "/api/v1/memberships/#{owner_membership.id}", { role: "member" }, as: admin
      expect(response).to have_http_status(:unprocessable_content)
      expect(owner_membership.reload).to be_admin
    end

    it "requires a role when updating a membership" do
      membership = project.memberships.find_by!(user: member)

      api :patch, "/api/v1/memberships/#{membership.id}", {}, as: admin

      expect(response).to have_http_status(:bad_request)
      expect(error["code"]).to eq("parameter_missing")
    end

    it "lets members leave, admins remove others, and protects the owner" do
      membership = project.memberships.find_by!(user: member)
      api :delete, "/api/v1/memberships/#{membership.id}", as: member
      expect(response).to have_http_status(:no_content)

      other = create(:membership, project:)
      api :delete, "/api/v1/memberships/#{other.id}", as: owner
      expect(response).to have_http_status(:no_content)

      owner_membership = project.memberships.find_by!(user: owner)
      api :delete, "/api/v1/memberships/#{owner_membership.id}", as: owner
      expect(response).to have_http_status(:unprocessable_content)
      expect(error["details"]["base"]).to include("The project owner cannot be removed")
    end

    it "forbids a member from removing a teammate" do
      teammate = create(:membership, project:)
      member

      api :delete, "/api/v1/memberships/#{teammate.id}", as: member

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "tags" do
    it "lets members create and list tags, and admins delete them" do
      api :post, "/api/v1/projects/#{project.id}/tags", { name: "Urgent Bug" }, as: member
      expect(response).to have_http_status(:created)
      expect(data["name"]).to eq("urgent bug")
      tag_id = data["id"]

      api :post, "/api/v1/projects/#{project.id}/tags", { name: "urgent bug" }, as: member
      expect(response).to have_http_status(:unprocessable_content)

      api :get, "/api/v1/projects/#{project.id}/tags", as: member
      expect(data.map { _1["name"] }).to eq([ "urgent bug" ])

      api :delete, "/api/v1/tags/#{tag_id}", as: member
      expect(response).to have_http_status(:forbidden)

      api :delete, "/api/v1/tags/#{tag_id}", as: admin
      expect(response).to have_http_status(:no_content)
    end

    it "hides tags from non-members" do
      tag = create(:tag, project:)

      api :get, "/api/v1/projects/#{project.id}/tags", as: outsider
      expect(response).to have_http_status(:not_found)

      api :delete, "/api/v1/tags/#{tag.id}", as: outsider
      expect(response).to have_http_status(:not_found)
    end
  end
end
