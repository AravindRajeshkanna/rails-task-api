require "rails_helper"

RSpec.describe "Organization audit events" do
  let(:ada) { create(:user, name: "Ada") }
  let(:grace) { create(:user, name: "Grace") }
  let(:linus) { create(:user, name: "Linus") }
  let(:outsider) { create(:user) }

  # Created through the API, so the actor is recorded the way it is in production.
  let(:organization_id) do
    api :post, "/api/v1/organizations", { name: "Acme" }, as: ada
    data.fetch("id")
  end
  let(:path) { "/api/v1/organizations/#{organization_id}/audit_events" }

  def join(user, role: "member")
    api :post, "/api/v1/organizations/#{organization_id}/invitations", { email_address: user.email_address, role: role }, as: ada
    token = OrganizationInvitation.find(data["id"]).generate_token_for(:acceptance)
    api :post, "/api/v1/invitations/accept", { token: token }, as: user
  end

  def history(**params)
    api :get, path, params.presence, as: ada
    data.map { |event| event.slice("auditable_type", "action").values.join(" ") }
  end

  it "records the organization's whole life, newest first, with who did it" do
    organization_id
    join(grace)
    grace_role = OrganizationMembership.find_by!(organization_id: organization_id, user: grace)
    api :patch, "/api/v1/organizations/#{organization_id}", { name: "Acme Inc" }, as: ada
    api :patch, "/api/v1/organizations/#{organization_id}/members/#{grace_role.id}", { role: "admin" }, as: ada
    api :delete, "/api/v1/organizations/#{organization_id}/members/#{grace_role.id}", as: ada

    expect(history).to eq([
      "OrganizationMembership destroy",
      "OrganizationMembership update",
      "Organization update",
      "OrganizationInvitation accept",   # Grace accepts ...
      "OrganizationMembership create",   # ... and becomes a member ...
      "OrganizationInvitation create",   # ... of the invitation Ada sent
      "OrganizationMembership create",  # Ada, the founder
      "Organization create"
    ])
  end

  it "says what changed and who changed it" do
    organization_id
    join(grace)
    grace_role = OrganizationMembership.find_by!(organization_id: organization_id, user: grace)
    api :patch, "/api/v1/organizations/#{organization_id}/members/#{grace_role.id}", { role: "admin" }, as: ada
    api :delete, "/api/v1/organizations/#{organization_id}/members/#{grace_role.id}", as: ada

    api :get, path, { auditable_type: "OrganizationMembership" }, as: ada
    removed, promoted, joined, = data

    expect(promoted).to include("action" => "update", "changes" => { "role" => %w[member admin] }, "actor" => { "id" => ada.id, "name" => "Ada" })
    expect(removed).to include("action" => "destroy", "actor" => { "id" => ada.id, "name" => "Ada" })
    expect(removed["changes"]).to include("role" => [ "admin", nil ], "user_id" => [ grace.id, nil ])
    expect(joined).to include("action" => "create", "actor" => { "id" => grace.id, "name" => "Grace" })
  end

  it "records who invited, who accepted and who withdrew" do
    organization_id
    api :post, "/api/v1/organizations/#{organization_id}/invitations", { email_address: "Pending@Example.com", role: "admin" }, as: ada
    invitation_id = data["id"]
    api :delete, "/api/v1/organizations/#{organization_id}/invitations/#{invitation_id}", as: ada

    api :get, path, { auditable_type: "OrganizationInvitation" }, as: ada
    revoked, invited = data

    expect(invited).to include("action" => "create", "actor" => { "id" => ada.id, "name" => "Ada" })
    expect(invited["changes"]).to include("email_address" => [ nil, "pending@example.com" ])
    expect(invited["changes"]["role"].last).to eq("admin")
    expect(revoked).to include("action" => "revoke", "auditable_id" => invitation_id)
  end

  it "records a leaver as the leaver" do
    organization_id
    join(linus)
    linus_role = OrganizationMembership.find_by!(organization_id: organization_id, user: linus)

    api :delete, "/api/v1/organizations/#{organization_id}/members/#{linus_role.id}", as: linus

    api :get, path, { auditable_type: "OrganizationMembership" }, as: ada
    expect(data.first).to include("action" => "destroy", "actor" => { "id" => linus.id, "name" => "Linus" })
  end

  it "keeps the history of a membership that no longer exists" do
    organization_id
    join(linus)
    linus_role = OrganizationMembership.find_by!(organization_id: organization_id, user: linus)
    api :delete, "/api/v1/organizations/#{organization_id}/members/#{linus_role.id}", as: ada

    expect(AuditEvent.where(auditable_type: "OrganizationMembership", auditable_id: linus_role.id).pluck(:action)).to contain_exactly("create", "destroy")
  end

  it "records teams: created, filled, granted a project, emptied and deleted, with the project's side in the project's feed" do
    organization_id
    join(grace)
    api :post, "/api/v1/organizations/#{organization_id}/teams", { name: "Backend" }, as: ada
    team_id = data["id"]
    api :post, "/api/v1/organizations/#{organization_id}/teams/#{team_id}/members", { user_id: grace.id }, as: ada
    membership_id = data["id"]
    api :post, "/api/v1/projects", { name: "Relaunch", organization_id: organization_id }, as: ada
    project_id = data["id"]
    api :post, "/api/v1/projects/#{project_id}/teams", { team_id: team_id, role: "admin" }, as: ada
    api :delete, "/api/v1/organizations/#{organization_id}/teams/#{team_id}/members/#{membership_id}", as: ada

    expect(history(auditable_type: "Team")).to eq([ "Team create" ])
    expect(history(auditable_type: "TeamMembership")).to eq([ "TeamMembership destroy", "TeamMembership create" ])
    expect(history(auditable_type: "ProjectTeam")).to eq([ "ProjectTeam create" ])

    api :get, "/api/v1/activity", { project_id: project_id, type: "ProjectTeam" }, as: ada
    expect(data.sole).to include("action" => "create", "project_id" => project_id)
    expect(data.sole["changes"]).to include("role" => [ "member", "admin" ], "team_id" => [ nil, team_id ])

    api :delete, "/api/v1/organizations/#{organization_id}/teams/#{team_id}", as: ada
    expect(history(auditable_type: "Team")).to eq([ "Team destroy", "Team create" ])
    expect(AuditEvent.where(auditable_type: "ProjectTeam", action: "destroy")).to be_empty # went with the team
  end

  it "filters by type and rejects an unknown one" do
    organization_id
    join(grace)

    expect(history(auditable_type: "Organization")).to eq([ "Organization create" ])

    api :get, path, { auditable_type: "Task" }, as: ada
    expect(response).to have_http_status(:bad_request)
    expect(error["code"]).to eq("invalid_parameter")
  end

  it "paginates" do
    organization_id
    join(grace)

    api :get, path, { limit: 2 }, as: ada

    expect(data.size).to eq(2)
    expect(meta["count"]).to be >= 5
  end

  it "is for owners only: admins and members get 403, outsiders 404, and nobody signed in 401" do
    organization_id
    join(grace, role: "admin")
    join(linus)

    [ grace, linus ].each do |user|
      api :get, path, as: user
      expect(response).to have_http_status(:forbidden)
    end
    api :get, path, as: outsider
    expect(response).to have_http_status(:not_found)
    api :get, path
    expect(response).to have_http_status(:unauthorized)
  end

  it "is not mixed into anyone's project feed, and other organizations' history stays out" do
    organization_id
    other = create(:organization, owner: outsider)
    create(:project, owner: ada, organization: Organization.find(organization_id))
    AuditEvent.where(organization_id: other.id).exists? or raise "setup: the other organization should have history"

    api :get, "/api/v1/activity", as: ada
    expect(data.pluck("auditable_type").uniq).to all(be_in(%w[Project Task Membership]))

    api :get, path, as: ada
    expect(data.pluck("auditable_id")).not_to include(other.id)
  end

  it "does not record the cascade when an organization is deleted, and does not block it" do
    organization_id
    join(grace)

    api :delete, "/api/v1/organizations/#{organization_id}", as: ada

    expect(response).to have_http_status(:no_content)
    expect(AuditEvent.where(auditable_type: "OrganizationMembership", action: "destroy")).to be_empty
    expect(AuditEvent.where(organization_id: organization_id)).to be_empty # unlinked, like a deleted project's
    expect(AuditEvent.where(auditable_type: "OrganizationMembership", action: "create").count).to eq(2)
  end
end
