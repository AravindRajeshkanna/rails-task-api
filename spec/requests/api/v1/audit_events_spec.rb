require "rails_helper"

RSpec.describe "Audit events" do
  let(:owner) { create(:user) }
  let(:project) { create(:project, owner: owner) }
  let(:member) { create(:membership, project:).user }
  let(:path) { "/api/v1/projects/#{project.id}/audit_events" }

  it "shows admins who changed what, newest first" do
    api :post, "/api/v1/projects/#{project.id}/tasks", { title: "Draft" }, as: owner
    task_id = data["id"]
    api :patch, "/api/v1/tasks/#{task_id}", { title: "Final", status: "done" }, as: owner
    api :delete, "/api/v1/tasks/#{task_id}", as: owner

    api :get, path, as: owner

    expect(response).to have_http_status(:ok)
    task_events = data.select { _1["auditable_type"] == "Task" }
    expect(task_events.map { _1["action"] }).to eq(%w[discard update create])
    expect(task_events.map { _1["actor"]["id"] }).to all(eq(owner.id))
    expect(task_events[1]["changes"]).to include("title" => %w[Draft Final], "status" => %w[todo done])
  end

  it "records a member being removed, and the project being deleted does not need it" do
    membership = create(:membership, project: project)

    api :delete, "/api/v1/memberships/#{membership.id}", as: owner
    api :get, path, { auditable_type: "Membership" }, as: owner

    expect(data.first).to include("action" => "destroy", "actor" => { "id" => owner.id, "name" => owner.name })
    expect(data.first["changes"]).to include("user_id" => [ membership.user_id, nil ], "role" => [ "member", nil ])

    expect { project.destroy! }.not_to raise_error # the cascade over its memberships writes no audit rows
  end

  it "filters by record type" do
    create(:task, project:)

    api :get, path, { auditable_type: "Project" }, as: owner

    expect(data.map { _1["auditable_type"] }.uniq).to eq([ "Project" ])
  end

  it "is for admins only" do
    api :get, path, as: member
    expect(response).to have_http_status(:forbidden)

    api :get, path, as: create(:user)
    expect(response).to have_http_status(:not_found)
  end

  it "paginates" do
    create_list(:task, 3, project:)

    api :get, path, { limit: 2 }, as: owner

    expect(data.size).to eq(2)
    expect(meta["count"]).to be >= 4
  end
end
