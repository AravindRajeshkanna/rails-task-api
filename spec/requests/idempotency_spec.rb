require "rails_helper"

RSpec.describe "Idempotency keys" do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let!(:project) { create(:project, owner: user) }
  let(:path) { "/api/v1/projects/#{project.id}/tasks" }
  let(:key) { SecureRandom.uuid }

  def post_task(body = { title: "Land on the moon" }, as: user, key: self.key, path: self.path)
    headers = key ? { "Idempotency-Key" => key } : {}
    api :post, path, body, as: as, headers: headers
  end

  it "answers a retry with the first response and creates nothing twice" do
    post_task
    first = [ response.status, response.body ]
    expect(response.headers["Idempotent-Replayed"]).to be_nil

    expect { post_task }.not_to change(Task, :count)

    expect([ response.status, response.body ]).to eq(first)
    expect(response.headers["Idempotent-Replayed"]).to eq("true")
    expect(response).to have_http_status(:created)
    expect(Task.where(title: "Land on the moon").count).to eq(1)
  end

  it "treats a new key as a new request, and no key as no protection (the header is optional)" do
    post_task
    post_task(key: SecureRandom.uuid)
    post_task(key: nil)
    post_task(key: nil)

    expect(Task.where(title: "Land on the moon").count).to eq(4)
  end

  it "refuses the same key for a different request, and does not run it" do
    post_task
    expect { post_task({ title: "Something else" }) }.not_to change(Task, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(error["code"]).to eq("idempotency_key_reused")

    other_project = create(:project, owner: user)
    expect { post_task(path: "/api/v1/projects/#{other_project.id}/tasks") }.not_to change(Task, :count)
    expect(error["code"]).to eq("idempotency_key_reused")
  end

  it "keeps each person's keys apart" do
    member = create(:membership, project: project, user: other_user).user
    post_task(as: user)
    post_task(as: member)

    expect(response).to have_http_status(:created)
    expect(Task.where(title: "Land on the moon").count).to eq(2)
  end

  it "refuses a request that arrives while the first is still running, and takes over one whose worker died" do
    fingerprint = OpenSSL::Digest::SHA256.hexdigest([ "POST", path, { title: "Land on the moon" }.to_json ].join("\n"))
    claim = IdempotencyKey.create!(user: user, key: key, request_fingerprint: fingerprint, locked_at: 5.seconds.ago, created_at: 5.seconds.ago)

    expect { post_task }.not_to change(Task, :count)
    expect(response).to have_http_status(:conflict)
    expect(error["code"]).to eq("idempotency_in_progress")
    expect(response.headers["Retry-After"]).to eq("1")

    claim.update_columns(locked_at: 2.minutes.ago)
    expect { post_task }.to change(Task, :count).by(1)
    expect(response).to have_http_status(:created)
    expect(claim.reload).to be_completed
  end

  it "does not remember a failure, so the retry runs again", :aggregate_failures do
    post_task({ title: "" })
    expect(response).to have_http_status(:unprocessable_content)
    expect(IdempotencyKey.count).to eq(0)

    post_task({ title: "" })
    expect(response.headers["Idempotent-Replayed"]).to be_nil
    expect(error["code"]).to eq("validation_failed")

    post_task({ title: "Now valid" }) # the key was released, so a corrected request may use it
    expect(response).to have_http_status(:created)
  end

  it "releases the key when the action blows up, and leaves no half-written record" do
    allow_any_instance_of(Task).to receive(:save!).and_raise(RuntimeError, "boom")

    expect { post_task }.to raise_error(RuntimeError, "boom")

    expect(IdempotencyKey.count).to eq(0)
    expect(Task.count).to eq(0)
  end

  it "stores the answer and the write together, so a rolled-back write leaves no answer behind" do
    allow_any_instance_of(IdempotencyKey).to receive(:complete!).and_raise(ActiveRecord::StatementInvalid, "disk full")

    expect { post_task }.to raise_error(ActiveRecord::StatementInvalid)

    expect(Task.count).to eq(0)
    expect(IdempotencyKey.count).to eq(0)
  end

  it "does not send an invitation twice" do
    organization = create(:organization, owner: user)
    invitation_path = "/api/v1/organizations/#{organization.id}/invitations"
    body = { email_address: "new.person@example.com", role: "member" }

    expect do
      3.times { post_task(body, path: invitation_path) }
    end.to have_enqueued_mail(OrganizationInvitationsMailer, :invite).once
    expect(response.headers["Idempotent-Replayed"]).to eq("true")
  end

  it "rejects a key that is empty of sense: too long, or with spaces and control characters" do
    [ "a" * 256, "has space", "tab\there", "naïve" ].each do |bad|
      post_task(key: bad)

      expect(response).to have_http_status(:bad_request), bad
      expect(error["details"]).to eq("parameter" => "Idempotency-Key")
    end
    expect(Task.count).to eq(0)
  end

  it "is not applied to reads, or to sign-in, whose answer holds a credential" do
    api :get, "/api/v1/projects", as: user, headers: { "Idempotency-Key" => key }
    expect(response).to have_http_status(:ok)

    2.times { api :post, "/api/v1/session", { email_address: user.email_address, password: "password123" }, headers: { "Idempotency-Key" => key } }
    expect(IdempotencyKey.count).to eq(0)
  end

  it "is applied to every action that creates something, and only those (a new create action must decide)" do
    controllers = Api::V1.constants.filter_map { |name| Api::V1.const_get(name) if name.to_s.end_with?("Controller") }
    creators = controllers.select { |controller| controller.action_methods.include?("create") }
    opted_in = creators.select { |controller| controller._process_action_callbacks.any? { |callback| callback.filter == :with_idempotency } }
    # Not opted in, on purpose: credentials in the answer, an upload, a token-for-everything, GraphQL (its own mutations).
    left_out = %w[AttachmentsController GraphqlController InvitationAcceptancesController PasswordsController RegistrationsController SessionsController]

    expect(creators.map(&:name).map { _1.demodulize }.sort - opted_in.map { _1.name.demodulize }).to match_array(left_out)
  end

  it "forgets keys after a day" do
    post_task
    IdempotencyKey.update_all(created_at: 25.hours.ago)

    expect { PurgeIdempotencyKeysJob.perform_now }.to change(IdempotencyKey, :count).by(-1)

    expect { post_task }.to change(Task, :count).by(1) # an expired key is a new key
  end

  it "counts what it did" do
    before = Observability::Metrics::IDEMPOTENCY.get(labels: { outcome: "replayed", source: "request" })
    post_task
    post_task

    expect(Observability::Metrics::IDEMPOTENCY.get(labels: { outcome: "replayed", source: "request" })).to eq(before + 1)
  end
end
