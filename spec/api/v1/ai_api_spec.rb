require "swagger_helper"

RSpec.describe "AI API", type: :request do
  ref = OpenapiSchemas.method(:ref)
  envelope = OpenapiSchemas.method(:envelope)

  let(:user) { create(:user) }
  let(:Authorization) { auth_headers(user)["Authorization"] }
  let!(:project) { create(:project, owner: user) }

  around { |example| travel_to(Time.utc(2026, 10, 29, 12, 0)) { example.run } }

  with_meta = ->(data_schema, meta_schema = nil) {
    { type: :object, properties: { data: data_schema, meta: meta_schema || { type: :object, properties: { usage: ref.call("AiUsage") } } }, required: [ :data ] }
  }

  path "/api/v1/ai/suggest_priority" do
    post "Suggest a priority and deadline" do
      tags "AI"
      description "Recommends a priority and estimates completion time. Pass `task_id`, or `project_id` with `title`. " \
                  "The estimate is grounded in similar finished tasks of the same project (embedding search)."
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: {
          task_id: { type: :integer }, project_id: { type: :integer }, title: { type: :string }, description: { type: :string },
          due_on: { type: :string, format: :date }, timezone: { type: :string, example: "Europe/Berlin", description: "IANA zone used to decide what 'today' is" }
        }
      }

      response "200", "A suggestion" do
        schema with_meta.call(ref.call("PrioritySuggestion"))
        let(:body) { { project_id: project.id, title: "Prepare the report", due_on: "2026-10-30" } }
        run_test! { expect(data).to include("priority" => "urgent", "predicted_due_on" => "2026-10-30") }
      end

      response "404", "Project or task not found, or not a member" do
        schema ref.call("Error")
        let(:body) { { project_id: create(:project).id, title: "x" } }
        run_test!
      end

      response "400", "title or project_id missing" do
        schema ref.call("Error")
        let(:body) { { project_id: project.id } }
        run_test!
      end

      response "429", "Rate limited, or the daily token budget is used up (see error.code; Retry-After says when to retry)" do
        schema ref.call("Error")
        before { AiUsage.create!(user: user, feature: "chat", input_tokens: Ai.config.daily_tokens_per_user) }
        let(:body) { { project_id: project.id, title: "x" } }
        run_test! do
          expect(error["code"]).to eq("ai_budget_exceeded")
          expect(response.headers["Retry-After"].to_i).to eq(12.hours.to_i)
        end
      end
    end
  end

  path "/api/v1/ai/suggest_tags" do
    post "Suggest tags" do
      tags "AI"
      description "Chooses up to five tags, preferring the project's existing ones. `allow_new: false` restricts the answer to existing tags."
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: { task_id: { type: :integer }, project_id: { type: :integer }, title: { type: :string }, description: { type: :string }, allow_new: { type: :boolean } }
      }

      response "200", "Tag suggestions, strongest first" do
        schema with_meta.call({ type: :array, items: ref.call("TagSuggestion") })
        before { create(:tag, project: project, name: "bug") }
        let(:body) { { project_id: project.id, title: "Fix crash on upload", allow_new: false } }
        run_test! { expect(data.map { |tag| tag["name"] }).to eq([ "bug" ]) }
      end
    end
  end

  path "/api/v1/ai/suggest_assignee" do
    post "Suggest an assignee" do
      tags "AI"
      description "Ranks project members by who finished similar tasks before, adjusted for current workload. " \
                  "Explainable and cheap: it uses embeddings, not text generation."
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: {
        type: :object, properties: { task_id: { type: :integer }, project_id: { type: :integer }, title: { type: :string }, description: { type: :string } }
      }

      response "200", "Up to three candidates, best first" do
        schema envelope.call({ type: :array, items: ref.call("AssigneeSuggestion") })
        let(:body) { { project_id: project.id, title: "Fix the login bug" } }
        run_test! { expect(data.first["user_id"]).to eq(user.id) }
      end
    end
  end

  path "/api/v1/ai/create_from_text" do
    post "Create a task from a sentence" do
      tags "AI"
      description "\"Remind me to review the PR next Tuesday\" becomes a task with a title and due date. " \
                  "Use `dry_run: true` to preview what the model understood without saving."
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: {
          project_id: { type: :integer }, text: { type: :string, maxLength: 1000 }, dry_run: { type: :boolean },
          timezone: { type: :string, example: "America/New_York" }
        },
        required: %i[project_id text]
      }

      response "201", "Task created" do
        schema with_meta.call(ref.call("Task"), { type: :object, properties: { usage: ref.call("AiUsage"), interpreted: ref.call("TaskDraft") } })
        let(:body) { { project_id: project.id, text: "Remind me to review the PR next Tuesday" } }
        run_test! { expect(data).to include("title" => "Review the PR", "due_on" => "2026-11-03") }
      end

      response "200", "Dry run: nothing saved" do
        schema with_meta.call(ref.call("TaskDraft"), { type: :object, properties: { usage: ref.call("AiUsage"), interpreted: ref.call("TaskDraft") } })
        let(:body) { { project_id: project.id, text: "Call Sam tomorrow", dry_run: true } }
        run_test! { expect(Task.count).to eq(0) }
      end

      response "502", "The model's answer was unusable" do
        schema ref.call("Error")
        let(:body) { { project_id: project.id, text: "x" } }
        before do
          @client = AiCore.client
          provider = AiCore::Providers::Fake.new(AiCore.configuration, responder: ->(_) { text_answer("sorry, no") })
          AiCore.client = AiCore::Client.new(provider: provider, config: AiCore.configuration)
        end
        after { AiCore.client = @client }
        run_test! { expect(error["code"]).to eq("ai_invalid_response") }
      end

      response "503", "AI is not configured on this server, or the provider is busy" do
        schema ref.call("Error")
        let(:body) { { project_id: project.id, text: "x" } }
        before { allow(Ai::Gateway.current).to receive(:enabled?).and_return(false) }
        run_test! { expect(error["code"]).to eq("ai_not_configured") }
      end
    end
  end

  path "/api/v1/ai/chat" do
    post "Chat with the task assistant" do
      tags "AI"
      description "A tool-using assistant that can list projects and tasks, create tasks and change task status as the " \
                  "caller, within the caller's permissions. Stateless: send earlier turns as plain text in `history` " \
                  "(at most 10 are used). Every change it makes is reported in `actions`. It cannot delete anything."
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: {
          message: { type: :string, maxLength: 2000 }, project_id: { type: :integer, description: "Optional: the project being viewed" },
          history: {
            type: :array,
            items: { type: :object, properties: { role: { type: :string, enum: %w[user assistant] }, text: { type: :string } } }
          }
        },
        required: [ :message ]
      }

      response "200", "The assistant's reply" do
        schema with_meta.call(ref.call("ChatReply"))
        let(:body) { { message: "create task: order laptops", project_id: project.id } }
        run_test! { expect(data["actions"].sole).to include("tool" => "create_task", "ok" => true) }
      end
    end
  end

  path "/api/v1/ai/usage" do
    get "My AI usage today" do
      tags "AI"
      description "Tokens used and remaining against today's (UTC) budget. Never rate limited."
      security [ { bearer_auth: [] } ]
      produces "application/json"

      response "200", "Today's usage" do
        schema envelope.call(ref.call("AiBudget"))
        before { AiUsage.create!(user: user, feature: "chat", input_tokens: 40, output_tokens: 10, cost_micros: 1_200) }
        run_test! { expect(data).to include("tokens_used" => 50, "calls" => 1) }
      end
    end
  end

  path "/api/v1/projects/{project_id}/summary" do
    get "Summarize project progress" do
      tags "AI"
      description "An AI-written status report built from task counts and recent activity. Cached per project version " \
                  "for ten minutes (`meta.cached`); `refresh=true` forces a new one and counts against your budget."
      security [ { bearer_auth: [] } ]
      produces "application/json"
      parameter name: :project_id, in: :path, type: :integer
      parameter name: :refresh, in: :query, type: :boolean, required: false
      parameter name: :timezone, in: :query, type: :string, required: false

      response "200", "The summary" do
        schema with_meta.call(ref.call("ProjectSummary"), { type: :object, properties: { cached: { type: :boolean }, usage: ref.call("AiUsage") } })
        let(:project_id) { project.id }
        before { create(:task, :done, project: project) }
        run_test! { expect(data["stats"]).to include("done" => 1) }
      end

      response "404", "Not found, or not a member" do
        schema ref.call("Error")
        let(:project_id) { create(:project).id }
        run_test!
      end
    end
  end
end
