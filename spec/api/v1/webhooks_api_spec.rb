require "swagger_helper"

RSpec.describe "Webhooks API", type: :request do
  ref = OpenapiSchemas.method(:ref)
  envelope = OpenapiSchemas.method(:envelope)

  let(:owner) { create(:user) }
  let(:project) { create(:project, owner: owner) }
  let(:Authorization) { auth_headers(owner)["Authorization"] }
  let!(:webhook) { create(:webhook, project:) }

  webhook_body = {
    type: :object,
    properties: {
      url: { type: :string, description: "https:// only in production. Private and loopback addresses are blocked." },
      events: { type: :array, items: { type: :string, enum: Webhook::EVENTS }, description: "Empty subscribes to everything" },
      active: { type: :boolean }
    }
  }

  path "/api/v1/projects/{project_id}/webhooks" do
    parameter name: :project_id, in: :path, type: :integer
    let(:project_id) { project.id }

    get "List webhooks" do
      tags "Webhooks"
      description "Project admins only."
      security [ { bearer_auth: [] } ]
      produces "application/json"
      parameter name: :page, in: :query, type: :integer, required: false
      parameter name: :limit, in: :query, type: :integer, required: false

      response "200", "Webhooks (secrets are never listed)" do
        schema envelope.call(ref.call("Webhook"), list: true)
        run_test!
      end
    end

    post "Register a webhook" do
      tags "Webhooks"
      description <<~MD
        Deliveries are `POST`ed as JSON with headers `X-TaskApi-Event`, `X-TaskApi-Delivery`, `X-TaskApi-Timestamp` and
        `X-TaskApi-Signature: sha256=<hex>`, where the signature is `HMAC-SHA256(secret, "<timestamp>.<raw body>")`.
        Failed deliveries are retried up to 6 times with back-off. The `secret` is returned only in this response.
      MD
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: webhook_body.merge(required: [ :url ])

      response "201", "Registered" do
        schema envelope.call(ref.call("Webhook"))
        let(:body) { { url: "https://hooks.example.com/in", events: %w[task.completed] } }
        run_test! { expect(data["secret"]).to be_present }
      end

      response "422", "Invalid URL or unknown event" do
        schema ref.call("Error")
        let(:body) { { url: "ftp://nope", events: %w[bogus] } }
        run_test!
      end
    end
  end

  path "/api/v1/webhooks/{id}" do
    parameter name: :id, in: :path, type: :integer
    let(:id) { webhook.id }

    get "Show a webhook" do
      tags "Webhooks"
      security [ { bearer_auth: [] } ]
      produces "application/json"
      response("200", "The webhook") { schema envelope.call(ref.call("Webhook")); run_test! }
    end

    patch "Update a webhook" do
      tags "Webhooks"
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: webhook_body

      response "200", "Updated" do
        schema envelope.call(ref.call("Webhook"))
        let(:body) { { active: false } }
        run_test!
      end
    end

    delete "Delete a webhook" do
      tags "Webhooks"
      security [ { bearer_auth: [] } ]
      response("204", "Deleted") { run_test! }
    end
  end

  path "/api/v1/webhooks/{webhook_id}/deliveries" do
    parameter name: :webhook_id, in: :path, type: :integer
    let(:webhook_id) { webhook.id }

    get "Delivery log" do
      tags "Webhooks"
      description "Every attempt's outcome, newest first. Use it to debug a receiver."
      security [ { bearer_auth: [] } ]
      produces "application/json"
      parameter name: :page, in: :query, type: :integer, required: false
      parameter name: :limit, in: :query, type: :integer, required: false

      response "200", "Deliveries" do
        schema envelope.call(ref.call("WebhookDelivery"), list: true)
        before { create(:webhook_delivery, webhook:) }
        run_test!
      end
    end
  end
end
