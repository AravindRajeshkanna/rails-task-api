require "rails_helper"

# The branches of Idempotency that no real action reaches yet: a response that is not a success but was rendered, not raised.
RSpec.describe Api::V1::BaseController, type: :controller do
  controller do
    idempotent :create

    def create
      skip_authorization
      Task.insert_all!([ { project_id: params[:project_id], creator_id: current_user.id, title: "written", created_at: Time.current, updated_at: Time.current } ])
      render json: { data: "answer" }, status: params[:status].to_i
    end
  end

  include AuthHelpers

  let(:user) { create(:user) }
  let(:project) { create(:project, owner: user) }

  before do
    routes.draw { post "create" => "api/v1/base#create" }
    request.headers["Authorization"] = auth_headers(user)["Authorization"]
    request.headers["Idempotency-Key"] = "k-1"
  end

  def call(status) = post(:create, params: { project_id: project.id, status: status })

  it "remembers a rendered success and replays it" do
    call(201)
    call(201)

    expect(response).to have_http_status(:created)
    expect(response.headers["Idempotent-Replayed"]).to eq("true")
    expect(Task.where(title: "written").count).to eq(1)
  end

  it "rolls back the write and releases the key for a rendered failure, 4xx or 5xx, so the retry runs again" do
    [ 422, 503 ].each do |status|
      expect { call(status) }.not_to change(Task, :count)

      expect(response).to have_http_status(status)
      expect(IdempotencyKey.count).to eq(0)
    end
  end

  it "keeps the answer and the write together: if the answer cannot be stored, the write is not kept" do
    allow_any_instance_of(IdempotencyKey).to receive(:complete!).and_raise(ActiveRecord::StatementInvalid, "disk full")

    expect { call(201) }.to raise_error(ActiveRecord::StatementInvalid)

    expect(Task.where(title: "written")).to be_empty
    expect(IdempotencyKey.count).to eq(0)
  end
end
