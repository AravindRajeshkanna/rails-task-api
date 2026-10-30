require "rails_helper"

RSpec.describe "Sparse fieldsets" do
  let(:user) { create(:user) }
  let!(:project) { create(:project, owner: user, description: "A project") }
  let!(:tasks) { create_list(:task, 3, project: project, creator: user, assignee: user, tag_names: %w[bug api]) }
  let(:path) { "/api/v1/projects/#{project.id}/tasks" }

  it "returns only the fields asked for, and always the id" do
    api :get, path, { fields: "title,status" }, as: user

    expect(response).to have_http_status(:ok)
    expect(data.map(&:keys).uniq).to eq([ %w[id title status] ])
    expect(data.pluck("title")).to match_array(tasks.map(&:title))
  end

  it "returns everything when nothing is asked for, as before" do
    api :get, path, as: user
    full = data.first.keys

    api :get, path, { fields: "" }, as: user

    expect(data.first.keys).to eq(full)
    expect(full).to include("id", "title", "description", "creator", "assignee", "tags", "attachments", "overdue", "lock_version")
  end

  it "includes associations and computed fields when asked for them, and only those" do
    api :get, path, { fields: "assignee,tags,overdue" }, as: user

    expect(data.first.keys).to match_array(%w[id assignee tags overdue])
    expect(data.first).to include("assignee" => { "id" => user.id, "name" => user.name }, "tags" => %w[api bug])
  end

  it "works on a single task, with the response key for attachments" do
    api :get, "/api/v1/tasks/#{tasks.first.id}", { fields: "title,attachments" }, as: user

    expect(data).to eq("id" => tasks.first.id, "title" => tasks.first.title, "attachments" => [])
  end

  it "works with cursor pagination and filters, which see the full records either way" do
    api :get, path, { fields: "id,status", cursor: "", status: "todo", limit: 2 }, as: user

    expect(data.size).to eq(2)
    expect(data.map(&:keys).uniq).to eq([ %w[id status] ])
    expect(meta).to include("has_more" => true)
  end

  it "loads only the associations the fields need" do
    all = count_queries { api :get, path, as: user }
    sparse = count_queries { api :get, path, { fields: "id,title" }, as: user }
    one_association = count_queries { api :get, path, { fields: "id,assignee" }, as: user }

    expect(sparse).to be < all
    expect(one_association).to be > sparse
    expect(one_association).to be < all
  end

  it "refuses a name it does not know, naming the ones it does, in the usual envelope" do
    api :get, path, { fields: "title,colour,secret" }, as: user

    expect(response).to have_http_status(:bad_request)
    expect(error).to include("code" => "invalid_parameter", "details" => { "parameter" => "fields" })
    expect(error["message"]).to start_with("unknown fields: colour, secret. Available: id, project_id, title")
  end

  it "cannot be used to reach what a task does not expose (no email, no internals)" do
    api :get, path, { fields: "creator,assignee" }, as: user

    expect(data.first["creator"].keys).to eq(%w[id name])
    expect(TaskResource.field_names).not_to include("email_address", "discarded_at", "search_vector", "creator_id")
  end

  it "rejects a fields that is not a list" do
    get path, params: { fields: [ "title" ] }, headers: auth_headers(user)

    expect(response).to have_http_status(:bad_request)
  end

  it "applies to projects too, and loads the owner only if asked" do
    api :get, "/api/v1/projects", { fields: "name" }, as: user
    expect(data.first.keys).to eq(%w[id name])

    api :get, "/api/v1/projects", { fields: "name,owner,role" }, as: user
    expect(data.first.keys).to match_array(%w[id name owner role])
    expect(data.first["owner"]).to eq("id" => user.id, "name" => user.name)
  end

  it "keeps the ETag honest: a sparse and a full response are different representations" do
    api :get, path, as: user
    full_etag = response.headers["ETag"]
    api :get, path, { fields: "id" }, as: user

    expect(response.headers["ETag"]).not_to eq(full_etag)
  end

  it "can be asked for exactly the fields every field-capable resource declares (a new attribute is selectable by default)" do
    expect(TaskResource.field_names).to include("title", "assignee", "attachments")
    expect(ProjectResource.field_names).to eq(%w[id name description organization_id created_at updated_at role owner])
  end
end
