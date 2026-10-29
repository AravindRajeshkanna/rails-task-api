require "rails_helper"

RSpec.describe "GET /api/v1/activity" do
  let(:ada) { create(:user, name: "Ada") }
  let(:grace) { create(:user, name: "Grace") }
  let(:outsider) { create(:user) }
  let!(:project) { create(:project, owner: ada) }
  let!(:other_project) { create(:project, owner: ada) }

  before do
    create(:membership, project: project, user: grace)
    api :post, "/api/v1/projects/#{project.id}/tasks", { title: "Draft the spec" }, as: ada
    @task_id = data.fetch("id")
    api :patch, "/api/v1/tasks/#{@task_id}", { status: "in_progress" }, as: grace
    api :post, "/api/v1/projects/#{other_project.id}/tasks", { title: "Elsewhere" }, as: ada
  end

  it "lists what happened in every project the caller belongs to, newest first, attributed" do
    api :get, "/api/v1/activity", as: grace

    expect(response).to have_http_status(:ok)
    expect(data.pluck("project_id").uniq).to eq([ project.id ]) # Grace is not in the other project
    update = data.find { |event| event["auditable_type"] == "Task" && event["action"] == "update" }
    expect(update).to include("auditable_id" => @task_id, "actor" => { "id" => grace.id, "name" => "Grace" })
    expect(update["changes"]).to include("status" => %w[todo in_progress])
    expect(data.pluck("created_at")).to eq(data.pluck("created_at").sort.reverse)
  end

  it "spans projects for someone who is in several" do
    api :get, "/api/v1/activity", as: ada

    expect(data.pluck("project_id").uniq).to contain_exactly(project.id, other_project.id)
  end

  it "shows a stranger nothing, and never another project's events" do
    api :get, "/api/v1/activity", as: outsider

    expect(response).to have_http_status(:ok)
    expect(data).to be_empty
  end

  it "does not reveal events of a project the caller asks for but is not in" do
    api :get, "/api/v1/activity", { project_id: other_project.id }, as: grace

    expect(data).to be_empty
  end

  it "hides a deleted project's history until it is restored" do
    other_project.discard

    api :get, "/api/v1/activity", as: ada

    expect(data.pluck("project_id").uniq).to eq([ project.id ])
  end

  it "filters by project and by type, and rejects types it does not know" do
    api :get, "/api/v1/activity", { project_id: project.id, type: "Membership" }, as: ada
    expect(data.pluck("auditable_type").uniq).to eq([ "Membership" ])

    api :get, "/api/v1/activity", { type: "Webhook" }, as: ada
    expect(response).to have_http_status(:bad_request)
    expect(error["code"]).to eq("invalid_parameter")
  end

  it "paginates" do
    api :get, "/api/v1/activity", { limit: 2 }, as: ada

    expect(data.size).to eq(2)
    expect(meta).to include("limit" => 2, "pages" => be > 1)
    expect(response.headers["Link"]).to include('rel="next"')
  end

  it "needs a token" do
    api :get, "/api/v1/activity"

    expect(response).to have_http_status(:unauthorized)
  end

  it "does not run a query per event" do
    api :get, "/api/v1/activity", as: ada # warm up the session lookup
    queries = count_queries { api :get, "/api/v1/activity", { limit: 100 }, as: ada }

    expect(queries).to be <= 12
  end
end
