require "rails_helper"

RSpec.describe "Organizations" do
  let(:ada) { create(:user, name: "Ada", email_address: "ada@example.com") }
  let(:grace) { create(:user, name: "Grace", email_address: "grace@example.com") }
  let(:linus) { create(:user, name: "Linus", email_address: "linus@example.com") }
  let(:stranger) { create(:user) }

  def create_organization(as:, name: "Acme")
    api :post, "/api/v1/organizations", { name: name }, as: as
    expect(response).to have_http_status(:created)
    data.fetch("id")
  end

  def add_member(org_id, user, role: nil, as:)
    api :post, "/api/v1/organizations/#{org_id}/members", { email_address: user.email_address, role: role }.compact, as: as
  end

  describe "the whole lifecycle" do
    it "creates an organization, builds a team, shares a project and tears it down" do
      org_id = create_organization(as: ada)
      expect(data).to include("name" => "Acme", "role" => "owner")

      # Ada adds Grace as an admin and Linus as a plain member.
      add_member(org_id, grace, role: "admin", as: ada)
      expect(response).to have_http_status(:created)
      expect(data).to include("role" => "admin", "user" => { "id" => grace.id, "name" => "Grace" })
      add_member(org_id, linus, as: ada)
      expect(data["role"]).to eq("member")

      # Linus creates a project in the organization. He is its owner and admin; nobody else is a member of it.
      api :post, "/api/v1/projects", { name: "Relaunch", organization_id: org_id }, as: linus
      expect(response).to have_http_status(:created)
      expect(data).to include("organization_id" => org_id, "role" => "admin")
      project_id = data.fetch("id")

      # Ada (owner) and Grace (admin) administer it without being members of it.
      [ ada, grace ].each do |user|
        api :get, "/api/v1/projects/#{project_id}", as: user
        expect(response).to have_http_status(:ok)
        expect(data["role"]).to eq("admin")
        api :get, "/api/v1/projects", as: user
        expect(data.pluck("id")).to include(project_id)
      end
      api :post, "/api/v1/projects/#{project_id}/tasks", { title: "Ship it" }, as: grace
      expect(response).to have_http_status(:created)

      # Someone outside the organization sees none of it, and cannot be added to its projects.
      api :get, "/api/v1/projects/#{project_id}", as: stranger
      expect(response).to have_http_status(:not_found)
      api :post, "/api/v1/projects/#{project_id}/memberships", { email_address: stranger.email_address }, as: linus
      expect(response).to have_http_status(:unprocessable_content)
      expect(error["details"]["user"]).to include("must be a member of the project's organization")

      # Removing Linus is refused while he owns the project ...
      linus_role = OrganizationMembership.find_by!(organization_id: org_id, user: linus)
      api :delete, "/api/v1/organizations/#{org_id}/members/#{linus_role.id}", as: ada
      expect(response).to have_http_status(:unprocessable_content)
      expect(error["details"]["base"].first).to include("still owns projects")

      # ... but Grace, who has no projects, can go, and her implicit access goes with her.
      grace_role = OrganizationMembership.find_by!(organization_id: org_id, user: grace)
      api :delete, "/api/v1/organizations/#{org_id}/members/#{grace_role.id}", as: ada
      expect(response).to have_http_status(:no_content)
      api :get, "/api/v1/projects/#{project_id}", as: grace
      expect(response).to have_http_status(:not_found)

      # The organization cannot be deleted while it has projects.
      api :delete, "/api/v1/organizations/#{org_id}", as: ada
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "who gets to do what" do
    let!(:org_id) { create_organization(as: ada) }

    before do
      add_member(org_id, grace, role: "admin", as: ada)
      add_member(org_id, linus, as: ada)
    end

    it "lists only my organizations" do
      create_organization(as: stranger, name: "Elsewhere")

      api :get, "/api/v1/organizations", as: linus

      expect(data.pluck("name")).to eq([ "Acme" ])
      expect(data.sole["role"]).to eq("member")
    end

    it "lets an admin add plain members but not other admins" do
      newcomer = create(:user)

      add_member(org_id, newcomer, role: "admin", as: grace)
      expect(response).to have_http_status(:forbidden)

      add_member(org_id, newcomer, as: grace)
      expect(response).to have_http_status(:created)
    end

    it "does not let an admin promote themselves, but lets the owner" do
      grace_role = OrganizationMembership.find_by!(organization_id: org_id, user: grace)

      api :patch, "/api/v1/organizations/#{org_id}/members/#{grace_role.id}", { role: "owner" }, as: grace
      expect(response).to have_http_status(:forbidden)

      api :patch, "/api/v1/organizations/#{org_id}/members/#{grace_role.id}", { role: "owner" }, as: ada
      expect(response).to have_http_status(:ok)
      expect(data["role"]).to eq("owner")
    end

    it "keeps at least one owner" do
      ada_role = OrganizationMembership.find_by!(organization_id: org_id, user: ada)

      api :patch, "/api/v1/organizations/#{org_id}/members/#{ada_role.id}", { role: "member" }, as: ada
      expect(response).to have_http_status(:unprocessable_content)

      api :delete, "/api/v1/organizations/#{org_id}/members/#{ada_role.id}", as: ada
      expect(response).to have_http_status(:unprocessable_content)
      expect(error["details"]["base"].first).to include("last owner")
    end

    it "lets a member leave on their own, taking their project access with them" do
      api :post, "/api/v1/projects", { name: "Side project", organization_id: org_id }, as: ada
      project_id = data.fetch("id")
      api :post, "/api/v1/projects/#{project_id}/memberships", { email_address: linus.email_address }, as: ada
      expect(response).to have_http_status(:created)
      linus_role = OrganizationMembership.find_by!(organization_id: org_id, user: linus)

      api :delete, "/api/v1/organizations/#{org_id}/members/#{linus_role.id}", as: linus
      expect(response).to have_http_status(:no_content)

      api :get, "/api/v1/projects/#{project_id}", as: linus
      expect(response).to have_http_status(:not_found)
      expect(Membership.where(project_id: project_id, user: linus)).not_to exist
    end

    it "renames only for owners and admins" do
      api :patch, "/api/v1/organizations/#{org_id}", { name: "Acme Inc" }, as: linus
      expect(response).to have_http_status(:forbidden)

      api :patch, "/api/v1/organizations/#{org_id}", { name: "Acme Inc" }, as: grace
      expect(response).to have_http_status(:ok)
      expect(data["name"]).to eq("Acme Inc")
    end

    it "deletes an empty organization, for its owner only" do
      api :delete, "/api/v1/organizations/#{org_id}", as: grace
      expect(response).to have_http_status(:forbidden)

      api :delete, "/api/v1/organizations/#{org_id}", as: ada
      expect(response).to have_http_status(:no_content)
      expect(Organization.exists?(org_id)).to be(false)
    end
  end

  describe "creating a project in an organization" do
    it "needs membership: someone else's organization is a 404, and the project is not created" do
      org_id = create_organization(as: ada)

      api :post, "/api/v1/projects", { name: "Sneaky", organization_id: org_id }, as: stranger

      expect(response).to have_http_status(:not_found)
      expect(Project.where(name: "Sneaky")).not_to exist
    end

    it "cannot be moved into (or out of) an organization afterwards" do
      org_id = create_organization(as: ada)
      api :post, "/api/v1/projects", { name: "Mine" }, as: ada
      project_id = data.fetch("id")

      api :patch, "/api/v1/projects/#{project_id}", { organization_id: org_id, name: "Mine too" }, as: ada

      expect(response).to have_http_status(:ok)
      expect(data["organization_id"]).to be_nil # not a permitted attribute: ignored
    end
  end

  it "validates names" do
    api :post, "/api/v1/organizations", { name: " " }, as: ada

    expect(response).to have_http_status(:unprocessable_content)
    expect(error["details"]).to include("name")
  end

  it "answers 404 for someone outside the organization and 401 without a token" do
    org_id = create_organization(as: ada)

    api :get, "/api/v1/organizations/#{org_id}", as: stranger
    expect(response).to have_http_status(:not_found)
    api :get, "/api/v1/organizations/#{org_id}/members", as: stranger
    expect(response).to have_http_status(:not_found)
    api :get, "/api/v1/organizations/#{org_id}"
    expect(response).to have_http_status(:unauthorized)
  end
end
