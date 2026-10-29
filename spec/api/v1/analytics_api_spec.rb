require "swagger_helper"

RSpec.describe "Analytics API", type: :request do
  ref = OpenapiSchemas.method(:ref)
  envelope = OpenapiSchemas.method(:envelope)

  let(:owner) { create(:user) }
  let(:Authorization) { auth_headers(owner)["Authorization"] }
  let!(:project) { create(:project, owner: owner) }

  path "/api/v1/projects/{project_id}/analytics" do
    parameter name: :project_id, in: :path, type: :integer
    let(:project_id) { project.id }

    get "Project analytics" do
      tags "Analytics"
      description "What a project dashboard needs, computed by the database: counts by status and priority, tasks created " \
                  "and completed per period, how long completed tasks took, and who is carrying what. Any member can read it. " \
                  "Cached for five minutes, and invalidated as soon as a task in the project changes."
      security [ { bearer_auth: [] } ]
      produces "application/json"
      parameter name: :from, in: :query, type: :string, format: :date, required: false,
                description: "First day, ISO 8601 (default: 29 days before `to`)"
      parameter name: :to, in: :query, type: :string, format: :date, required: false, description: "Last day, ISO 8601 (default: today, UTC)"
      parameter name: :interval, in: :query, required: false, schema: { type: :string, enum: %w[day week month], default: "week" },
                description: "Bucket size for `throughput`. A range may span at most 120 buckets."

      response "200", "The report" do
        schema envelope.call(ref.call("ProjectAnalytics"))
        before do
          create(:task, project: project, status: :done)
          create(:task, project: project, assignee: owner, due_on: 3.days.ago.to_date)
        end
        run_test! do
          expect(data["totals"]).to include("total" => 2, "done" => 1, "overdue" => 1)
          expect(data["throughput"].last).to include("created" => 2)
        end
      end

      response "422", "Invalid range or interval (every problem is listed in `details`)" do
        schema ref.call("Error")
        let(:interval) { "year" }
        run_test!
      end

      response "404", "Not found, or not a member" do
        schema ref.call("Error")
        let(:project_id) { create(:project).id }
        run_test!
      end

      response "401", "Missing or invalid token" do
        schema ref.call("Error")
        let(:Authorization) { nil }
        run_test!
      end
    end
  end
end
