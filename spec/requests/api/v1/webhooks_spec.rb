require "rails_helper"

RSpec.describe "Webhooks" do
  let(:owner) { create(:user) }
  let(:project) { create(:project, owner: owner) }
  let(:member) { create(:membership, project:).user }
  let(:outsider) { create(:user) }
  let(:path) { "/api/v1/projects/#{project.id}/webhooks" }

  describe "POST /api/v1/projects/:project_id/webhooks" do
    it "registers a webhook and reveals the signing secret exactly once" do
      api :post, path, { url: "https://hooks.example.com/in", events: %w[task.completed] }, as: owner

      expect(response).to have_http_status(:created)
      expect(data).to include("url" => "https://hooks.example.com/in", "events" => [ "task.completed" ], "active" => true)
      expect(data["secret"]).to match(/\A\h{64}\z/)

      api :get, "/api/v1/webhooks/#{data['id']}", as: owner
      expect(data).not_to have_key("secret")
    end

    it "answers 503 and Retry-After, not 500, when KMS cannot make a key for the secret, and creates nothing" do
      down = Class.new { def generate_data_key(**) = raise(KmsEncryption::Unavailable.new("AccessDeniedException: no", reason: :access_denied)) }.new
      allow(KmsEncryption.configuration).to receive(:client).and_return(down)

      expect { api :post, path, { url: "https://hooks.example.com/in" }, as: owner }.not_to change(Webhook, :count)

      expect(response).to have_http_status(:service_unavailable)
      expect(response.headers["Retry-After"]).to eq("5")
      expect(error).to include("code" => "encryption_unavailable")
      expect(response.body).not_to include("AccessDenied") # why is for the logs, not the client
    end

    it "validates url and events" do
      api :post, path, { url: "javascript:alert(1)", events: %w[nope] }, as: owner

      expect(response).to have_http_status(:unprocessable_content)
      expect(error["details"].keys).to contain_exactly("url", "events")
    end

    it "is for admins only" do
      api :post, path, { url: "https://hooks.example.com/in" }, as: member
      expect(response).to have_http_status(:forbidden)

      api :post, path, { url: "https://hooks.example.com/in" }, as: outsider
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "listing, updating and deleting" do
    let!(:webhook) { create(:webhook, project:) }

    it "lists webhooks without secrets" do
      api :get, path, as: owner

      expect(data.sole).to include("id" => webhook.id)
      expect(data.sole).not_to have_key("secret")
    end

    it "keeps webhook details away from members" do
      api :get, path, as: member
      expect(response).to have_http_status(:forbidden)

      api :get, "/api/v1/webhooks/#{webhook.id}", as: member
      expect(response).to have_http_status(:not_found)
    end

    it "updates and deletes" do
      api :patch, "/api/v1/webhooks/#{webhook.id}", { active: false, events: %w[comment.created] }, as: owner
      expect(response).to have_http_status(:ok)
      expect(webhook.reload).to have_attributes(active: false, events: %w[comment.created])

      api :delete, "/api/v1/webhooks/#{webhook.id}", as: owner
      expect(response).to have_http_status(:no_content)
      expect(Webhook.exists?(webhook.id)).to be(false)
    end

    it "shows the delivery log, newest first" do
      older = create(:webhook_delivery, webhook:, created_at: 2.hours.ago)
      newer = create(:webhook_delivery, webhook:, response_status: 200, delivered_at: Time.current)

      api :get, "/api/v1/webhooks/#{webhook.id}/deliveries", as: owner

      expect(data.map { _1["id"] }).to eq([ newer.id, older.id ])
      expect(data.first).to include("status" => "delivered", "response_status" => 200, "event" => "task.created")
      expect(data.last["status"]).to eq("pending")
    end
  end

  describe "end to end" do
    let!(:webhook) { create(:webhook, project:, events: %w[task.completed comment.created], url: "https://hooks.example.com/in") }

    before { stub_dns("hooks.example.com" => "203.0.113.10") }

    it "delivers a signed event when a task is completed through the API" do
      task = create(:task, project:)
      stub = stub_request(:post, "https://hooks.example.com/in").to_return(status: 200)

      perform_enqueued_jobs do
        api :patch, "/api/v1/tasks/#{task.id}", { status: "done" }, as: owner
      end

      expect(stub).to have_been_requested.once
      delivery = webhook.deliveries.sole
      expect(delivery).to have_attributes(event: "task.completed", response_status: 200)
      expect(delivery.delivered_at).to be_present
      expect(delivery.payload).to include("event" => "task.completed", "data" => include("id" => task.id, "status" => "done"))

      expect(a_request(:post, "https://hooks.example.com/in").with { |req|
        timestamp = req.headers["X-Taskapi-Timestamp"]
        expected = OpenSSL::HMAC.hexdigest("SHA256", webhook.secret, "#{timestamp}.#{req.body}")
        req.headers["X-Taskapi-Signature"] == "sha256=#{expected}" &&
          req.headers["X-Taskapi-Event"] == "task.completed" &&
          JSON.parse(req.body)["data"]["id"] == task.id
      }).to have_been_made.once
    end

    it "does not deliver events the webhook did not ask for" do
      task = create(:task, project:)

      expect { api :patch, "/api/v1/tasks/#{task.id}", { title: "Just a rename" }, as: owner }
        .not_to have_enqueued_job(WebhookDeliveryJob)
    end

    it "skips inactive webhooks and other projects' webhooks" do
      webhook.update!(active: false)
      create(:webhook, events: [])
      task = create(:task, project:)

      expect { api :patch, "/api/v1/tasks/#{task.id}", { status: "done" }, as: owner }
        .not_to have_enqueued_job(WebhookDeliveryJob)
    end

    it "delivers comment events" do
      task = create(:task, project:)

      expect { api :post, "/api/v1/tasks/#{task.id}/comments", { body: "Looks good" }, as: owner }
        .to have_enqueued_job(WebhookDeliveryJob)

      expect(webhook.deliveries.sole.payload["data"]).to include("body" => "Looks good")
    end
  end
end
