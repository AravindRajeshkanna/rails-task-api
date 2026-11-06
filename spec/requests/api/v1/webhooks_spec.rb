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

    it "keeps the secret out of the idempotency record: a retry gets the same webhook without it, and the table never held it" do
      headers = { "Idempotency-Key" => "register-once" }
      api :post, path, { url: "https://hooks.example.com/in" }, as: owner, headers: headers
      secret = data["secret"]
      expect(secret).to match(/\A\h{64}\z/)

      expect { api :post, path, { url: "https://hooks.example.com/in" }, as: owner, headers: headers }.not_to change(Webhook, :count)

      expect(response).to have_http_status(:created)
      expect(response.headers["Idempotent-Replayed"]).to eq("true")
      expect(data).to include("id" => Webhook.last.id, "url" => "https://hooks.example.com/in")
      expect(data).not_to have_key("secret")
      expect(IdempotencyKey.pluck(:response_body).join).not_to include(secret)
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

  describe "rotating the signing secret (ADR 78)" do
    let!(:webhook) { create(:webhook, project:, events: %w[task.completed], url: "https://hooks.example.com/in") }
    let(:rotate) { "/api/v1/webhooks/#{webhook.id}/rotate_secret" }
    let(:promote) { "/api/v1/webhooks/#{webhook.id}/promote_secret" }
    let(:cancel) { "/api/v1/webhooks/#{webhook.id}/cancel_rotation" }

    before { stub_dns("hooks.example.com" => "203.0.113.10") }

    # What the receiver is sent for a completed task: the headers, and the HMAC of each secret it might hold.
    def receive_an_event(secrets)
      task = create(:task, project:)
      sent = []
      stub_request(:post, "https://hooks.example.com/in").to_return { |request| sent << request; { status: 200 } }
      perform_enqueued_jobs { api :patch, "/api/v1/tasks/#{task.id}", { status: "done" }, as: owner }
      request = sent.sole
      timestamp = request.headers["X-Taskapi-Timestamp"]
      verifies = ->(header, secret) { request.headers[header] == "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "#{timestamp}.#{request.body}")}" }
      secrets.to_h { |name, secret| [ name, [ verifies.call("X-Taskapi-Signature", secret), verifies.call("X-Taskapi-Signature-Next", secret) ] ] }
    end

    it "rotates in a new secret, shows it once, and leaves the current one untouched" do
      current = webhook.secret

      api :post, rotate, as: owner

      expect(response).to have_http_status(:ok)
      expect(data).to include("id" => webhook.id, "rotating" => true, "rotation_started_at" => be_present)
      expect(data["next_secret"]).to match(/\A\h{64}\z/)
      expect(data["next_secret"]).not_to eq(current)
      expect(data).not_to have_key("secret")
      expect(webhook.reload.secret).to eq(current)

      api :get, "/api/v1/webhooks/#{webhook.id}", as: owner
      expect(data).to include("rotating" => true)
      expect(data).not_to have_key("next_secret")
      expect(data).not_to have_key("secret")

      api :get, path, as: owner
      expect(data.sole).to include("rotating" => true)
      expect(response.body).not_to include(webhook.reload.next_secret)
    end

    it "says whether a rotation is under way without decrypting anything: listing webhooks asks KMS for nothing" do
      webhook.begin_secret_rotation!
      KmsEncryption.cache.clear
      KmsEncryption.client.reset!

      api :get, path, as: owner
      api :get, "/api/v1/webhooks/#{webhook.id}", as: owner

      expect(data).to include("rotating" => true)
      expect(KmsEncryption.client.requests).to be_empty
    end

    it "walks a receiver through it without a single rejected event: before, during, after promoting" do
      old = webhook.secret

      expect(receive_an_event(old: old)).to eq(old: [ true, false ])

      api :post, rotate, as: owner
      new_secret = data["next_secret"]
      during = receive_an_event(old: old, new: new_secret)
      expect(during).to eq(old: [ true, false ], new: [ false, true ]) # either secret verifies one of the two headers, and nobody is refused

      api :post, promote, as: owner
      expect(response).to have_http_status(:ok)
      expect(data).to include("rotating" => false, "rotation_started_at" => nil)
      expect(receive_an_event(old: old, new: new_secret)).to eq(old: [ false, false ], new: [ true, false ])
      expect(webhook.reload).to have_attributes(secret: new_secret, next_secret: nil)
    end

    it "can be cancelled, and then the old secret is the only one again" do
      old = webhook.secret
      api :post, rotate, as: owner
      new_secret = data["next_secret"]

      api :post, cancel, as: owner

      expect(response).to have_http_status(:ok)
      expect(data).to include("rotating" => false)
      expect(receive_an_event(old: old, new: new_secret)).to eq(old: [ true, false ], new: [ false, false ])
    end

    it "makes a different new secret each time it is asked, so that one lost with its answer is replaced and a retry needs no key" do
      api :post, rotate, as: owner
      first = data["next_secret"]
      api :post, rotate, as: owner
      second = data["next_secret"]

      expect(second).not_to eq(first)
      expect(webhook.reload.next_secret).to eq(second)
      expect(IdempotencyKey.count).to eq(0)
    end

    it "does not remember a new secret in the idempotency table, with or without a key" do
      api :post, rotate, {}, as: owner, headers: { "Idempotency-Key" => "rotate-once" }

      expect(IdempotencyKey.count).to eq(0)
      expect(response.headers).not_to have_key("Idempotent-Replayed")
    end

    it "answers 409 no_rotation_in_progress to promoting or cancelling when no secret is being rotated in, and changes nothing" do
      current = webhook.secret

      [ promote, cancel ].each do |action|
        api :post, action, as: owner

        expect(response).to have_http_status(:conflict)
        expect(error).to include("code" => "no_rotation_in_progress")
      end
      expect(webhook.reload.secret).to eq(current)
    end

    it "is for admins of the project only: a member is refused, an outsider does not see the webhook, and nothing changes" do
      [ rotate, promote, cancel ].each do |action|
        api :post, action, as: member
        expect(response).to have_http_status(:not_found) # by id, a webhook is hidden from anyone who is not an admin of its project

        api :post, action, as: outsider
        expect(response).to have_http_status(:not_found)
      end
      expect(webhook.reload).not_to be_rotating
    end

    it "needs a signed-in person" do
      post rotate

      expect(response).to have_http_status(:unauthorized)
    end

    it "answers 503 and Retry-After when KMS cannot encrypt the new secret, and starts no rotation" do
      down = Class.new { def generate_data_key(**) = raise(KmsEncryption::Unavailable.new("AccessDeniedException: no", reason: :access_denied)) }.new
      allow(KmsEncryption.configuration).to receive(:client).and_return(down)

      api :post, rotate, as: owner

      expect(response).to have_http_status(:service_unavailable)
      expect(error).to include("code" => "encryption_unavailable")
      expect(webhook.reload).not_to be_rotating
    end

    it "keeps promoting from half doing it when KMS fails midway: the new secret is still there to try again" do
      api :post, rotate, as: owner
      new_secret = data["next_secret"]
      old = webhook.reload.secret
      down = Class.new { def generate_data_key(**) = raise(KmsEncryption::Unavailable.new("ThrottlingException", reason: :throttled)) }.new
      allow(KmsEncryption.configuration).to receive(:client).and_return(down)

      api :post, promote, as: owner

      expect(response).to have_http_status(:service_unavailable)
      allow(KmsEncryption.configuration).to receive(:client).and_call_original
      expect(webhook.reload).to have_attributes(secret: old, next_secret: new_secret)
      expect(webhook).to be_rotating
    end

    it "limits how often one person starts a rotation: 20 an hour" do
      allow(Rails.cache).to receive(:increment).and_return(20) # the test cache counts nothing
      api :post, rotate, as: owner
      expect(response).to have_http_status(:ok)

      allow(Rails.cache).to receive(:increment).and_return(21)
      api :post, rotate, as: owner

      expect(response).to have_http_status(:too_many_requests)
      expect(error).to include("code" => "rate_limited")
      expect(webhook.reload.rotation_started_at).to be_present # the first one only
    end

    it "counts the rotations of each person apart: the budget is the person's, not the address's they happen to come from" do
      allow(Rails.cache).to receive(:increment).and_return(1)

      api :post, rotate, as: owner

      expect(Rails.cache).to have_received(:increment).with(a_string_ending_with(":#{owner.id}"), 1, expires_in: 1.hour)
    end

    it "asks the policy as well as the scope: an admin the policy refuses is refused (the scope alone would let them through)" do
      [ [ rotate, :rotate_secret? ], [ promote, :promote_secret? ], [ cancel, :cancel_rotation? ] ].each do |action, permission|
        allow_any_instance_of(WebhookPolicy).to receive(permission).and_return(false)

        api :post, action, as: owner

        expect(response).to have_http_status(:forbidden), action
      end
      expect(webhook.reload).not_to be_rotating
    end

    it "records each step as an event with the webhook, the project and the person, and never a secret" do
      events = record_events do
        api :post, rotate, as: owner
        api :post, promote, as: owner
        api :post, rotate, as: owner
        api :post, cancel, as: owner
      end

      expect(events.payloads("webhook.secret_rotation_started").first).to eq(webhook_id: webhook.id, project_id: project.id, actor_id: owner.id)
      expect(events.payloads("webhook.secret_rotation_promoted").sole.keys).to eq(%i[webhook_id project_id actor_id])
      expect(events.payloads("webhook.secret_rotation_cancelled").sole.keys).to eq(%i[webhook_id project_id actor_id])
      expect(events.events.to_s).not_to include(webhook.reload.secret)
    end
  end
end
