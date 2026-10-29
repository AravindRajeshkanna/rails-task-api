require "rails_helper"

RSpec.describe "GET /api/v1/projects/:id/analytics" do
  let(:owner) { create(:user) }
  let(:member) { create(:user) }
  let(:outsider) { create(:user) }
  let!(:project) { create(:project, owner: owner) }
  let(:path) { "/api/v1/projects/#{project.id}/analytics" }

  before do
    create(:membership, project: project, user: member)
    create(:task, project: project, status: :done)
    create(:task, project: project, assignee: member, due_on: 2.days.ago.to_date)
  end

  it "returns the report to any member of the project" do
    api :get, path, as: member

    expect(response).to have_http_status(:ok)
    expect(data.keys).to contain_exactly("range", "totals", "by_status", "by_priority", "throughput", "cycle_time_hours", "workload")
    expect(data["totals"]).to include("total" => 2, "open" => 1, "done" => 1, "overdue" => 1)
    expect(data["workload"].sole).to include("open" => 1, "overdue" => 1, "assignee" => { "id" => member.id, "name" => member.name })
    expect(data["range"]).to include("interval" => "week")
  end

  it "accepts a range and an interval" do
    api :get, path, { from: "2026-01-01", to: "2026-03-31", interval: "month" }, as: owner

    expect(response).to have_http_status(:ok)
    expect(data["range"]).to eq("from" => "2026-01-01", "to" => "2026-03-31", "interval" => "month")
    expect(data["throughput"].pluck("period")).to eq(%w[2026-01-01 2026-02-01 2026-03-01])
  end

  it "explains every problem with the parameters at once, as a 422" do
    api :get, path, { from: "soon", interval: "year" }, as: owner

    expect(response).to have_http_status(:unprocessable_content)
    expect(error).to include("code" => "validation_failed")
    expect(error["details"].keys).to contain_exactly("from", "interval")
  end

  it "refuses a range that would produce an unreasonable number of buckets" do
    api :get, path, { from: "2020-01-01", to: "2026-01-01", interval: "day" }, as: owner

    expect(response).to have_http_status(:unprocessable_content)
  end

  it "is a 404 for someone outside the project and a 401 without a token" do
    api :get, path, as: outsider
    expect(response).to have_http_status(:not_found)

    api :get, path
    expect(response).to have_http_status(:unauthorized)
  end

  it "is a 404 once the project is deleted" do
    project.discard

    api :get, path, as: owner

    expect(response).to have_http_status(:not_found)
  end

  it "serves the cached report until a task changes" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    api :get, path, as: owner
    expect(data.dig("totals", "total")).to eq(2)

    allow(Analytics::ProjectReport).to receive(:new).and_call_original
    api :get, path, as: owner
    expect(Analytics::ProjectReport).not_to have_received(:new)

    create(:task, project: project) # touches the project, which changes the cache key
    api :get, path, as: owner
    expect(data.dig("totals", "total")).to eq(3)
  ensure
    Rails.cache = original_cache
  end
end
