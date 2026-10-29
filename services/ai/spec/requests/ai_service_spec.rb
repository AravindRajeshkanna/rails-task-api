require "rails_helper"

RSpec.describe "AI service", type: :request do
  let(:token) { "service-secret" }
  let(:headers) { { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" } }
  let(:json) { JSON.parse(response.body) }

  around do |example|
    ENV["AI_SERVICE_TOKEN"] = token
    example.run
  ensure
    ENV.delete("AI_SERVICE_TOKEN")
  end

  def post_json(path, body, headers: self.headers) = post(path, params: body.to_json, headers: headers)

  # Swaps the provider for one that scripts the answer.
  def with_provider(responder)
    previous = AiCore.client
    AiCore.client = AiCore::Client.new(provider: AiCore::Providers::Fake.new(AiCore.configuration, responder: responder), config: AiCore.configuration)
    yield
  ensure
    AiCore.client = previous
  end

  describe "authentication" do
    it "rejects missing and wrong tokens, and tells the caller how to authenticate" do
      post_json("/v1/embeddings", { text: "x" }, headers: { "Content-Type" => "application/json" })
      expect(response).to have_http_status(:unauthorized)
      expect(response.headers["WWW-Authenticate"]).to include("Bearer")

      post_json("/v1/embeddings", { text: "x" }, headers: { "Authorization" => "Bearer nope", "Content-Type" => "application/json" })
      expect(response).to have_http_status(:unauthorized)
      expect(json["error"]["code"]).to eq("unauthorized")
    end

    it "leaves the health check open" do
      get "/up"

      expect(response).to have_http_status(:ok)
    end

    it "answers unknown routes in the same envelope" do
      post_json("/v1/nope", {})

      expect(response).to have_http_status(:not_found)
      expect(json["error"]["code"]).to eq("not_found")
    end
  end

  describe "POST /v1/features/:name" do
    it "runs a feature and returns validated output with usage" do
      post_json("/v1/features/parse_task", { input: { text: "Remind me to review the PR next Tuesday", today: "2026-10-29", members: [], tags: [] } })

      expect(response).to have_http_status(:ok)
      expect(json["output"]).to include("title" => "Review the PR", "due_on" => "2026-11-03")
      expect(json["usage"]).to include("model_id" => "fake", "input_tokens" => be_positive)
    end

    it "answers 404 for a feature it does not have" do
      post_json("/v1/features/summon_demon", { input: {} })

      expect(response).to have_http_status(:not_found)
      expect(json["error"]["code"]).to eq("unknown_feature")
    end

    it "needs an input object" do
      post_json("/v1/features/parse_task", {})

      expect(response).to have_http_status(:bad_request)
      expect(json["error"]["code"]).to eq("invalid_request")
    end

    it "refuses oversized bodies before parsing them" do
      post_json("/v1/features/parse_task", { input: { text: "x" * 600_000 } })

      expect(response).to have_http_status(:content_too_large)
    end

    {
      AiCore::Unavailable => [ 503, "ai_unavailable" ],
      AiCore::InvalidResponse => [ 502, "ai_invalid_response" ],
      AiCore::ConfigurationError => [ 503, "ai_not_configured" ],
      AiCore::Error => [ 502, "ai_error" ]
    }.each do |error_class, (status, code)|
      it "maps #{error_class.name.demodulize} to #{status} #{code}" do
        with_provider(->(_) { raise error_class, "boom" }) do
          post_json("/v1/features/parse_task", { input: { text: "x", today: "2026-10-29" } })
        end

        expect(response.status).to eq(status)
        expect(json["error"]["code"]).to eq(code)
      end
    end

    it "asks callers to retry shortly when the provider is throttling" do
      with_provider(->(_) { raise AiCore::Unavailable, "throttled" }) do
        post_json("/v1/features/parse_task", { input: { text: "x", today: "2026-10-29" } })
      end

      expect(response.headers["Retry-After"]).to eq("5")
    end

    it "does not log prompts" do
      logged = []
      allow(Rails.logger).to receive(:info) { |line| logged << line.to_s }
      post_json("/v1/features/parse_task", { input: { text: "TOP SECRET PLAN", today: "2026-10-29" } })

      expect(logged.join).not_to include("TOP SECRET PLAN")
    end
  end

  describe "POST /v1/converse" do
    let(:body) do
      { system: "You help.", messages: [ { role: "user", content: [ { text: "show overdue tasks" } ] } ],
        tools: [ { name: "list_tasks", description: "d", input_schema: { type: "object", properties: {} } } ] }
    end

    it "relays one tool-use turn" do
      post_json("/v1/converse", body)

      expect(response).to have_http_status(:ok)
      expect(json["message"]["content"].first["tool_use"]).to include("name" => "list_tasks")
      expect(json["stop_reason"]).to eq("tool_use")
    end

    it "round-trips tool results" do
      turn = { role: "user", content: [ { tool_result: { tool_use_id: "x", content: [ { text: "[]" } ] } } ] }
      post_json("/v1/converse", body.merge(messages: [ turn ]))

      expect(json["message"]["content"].first["text"]).to start_with("Done.")
    end

    it "caps messages and tools" do
      post_json("/v1/converse", body.merge(messages: Array.new(61) { { role: "user", content: [ { text: "x" } ] } }))

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "POST /v1/embeddings" do
    it "returns a vector of the configured size" do
      post_json("/v1/embeddings", { text: "fix the login bug" })

      expect(json["vector"].length).to eq(AiCore.configuration.embedding_dimensions)
      expect(json["usage"]["model_id"]).to eq("fake-embedding")
    end

    it "rejects empty text" do
      post_json("/v1/embeddings", { text: "   " })

      expect(response).to have_http_status(:bad_request)
      expect(json["error"]["code"]).to eq("invalid_request")
    end
  end

  describe "GET /metrics" do
    it "reports calls and tokens" do
      post_json("/v1/embeddings", { text: "hello" })

      get "/metrics"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('ai_service_requests_total{feature="embedding",outcome="ok"}', "service_http_requests_total")
    end
  end
end
