require "rails_helper"

RSpec.describe "Error responses" do
  # The test environment shows Rails' HTML debug page; behave like production instead,
  # where config.exceptions_app (ErrorsController) renders every failure.
  around do |example|
    env_config = Rails.application.env_config
    original = env_config.slice("action_dispatch.show_exceptions", "action_dispatch.show_detailed_exceptions")
    env_config["action_dispatch.show_exceptions"] = :all
    env_config["action_dispatch.show_detailed_exceptions"] = false
    example.run
  ensure
    env_config.merge!(original)
  end

  it "renders unknown routes as a JSON 404 envelope" do
    get "/api/v1/nonsense"

    expect(response).to have_http_status(:not_found)
    expect(response.media_type).to eq("application/json")
    expect(error).to eq("status" => 404, "code" => "not_found", "message" => "Not Found")
  end

  it "renders unparseable JSON as a 400 envelope" do
    post "/api/v1/session", params: "{not json", headers: { "Content-Type" => "application/json" }

    expect(response).to have_http_status(:bad_request)
    expect(error).to include("status" => 400, "code" => "bad_request")
  end

  it "does not leak exception details on a 500" do
    allow_any_instance_of(Api::V1::MeController).to receive(:show).and_raise(RuntimeError, "secret internals")
    user = create(:user)

    get "/api/v1/me", headers: auth_headers(user)

    expect(response).to have_http_status(:internal_server_error)
    expect(response.body).not_to include("secret internals")
    expect(error).to include("status" => 500, "code" => "internal_server_error")
  end

  it "answers the health check" do
    get "/up"

    expect(response).to have_http_status(:ok)
  end
end
