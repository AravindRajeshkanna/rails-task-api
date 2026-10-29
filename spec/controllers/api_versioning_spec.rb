require "rails_helper"

RSpec.describe ApiVersioning, type: :controller do
  controller(Api::V1::BaseController) do
    skip_after_action :verify_authorized
    skip_after_action :verify_policy_scoped, raise: false

    def index
      response.headers["Link"] = [ response.headers["Link"], '<https://example.test/page2>; rel="next"' ].compact.join(", ")
      head :ok
    end

    def show
      raise ActiveRecord::RecordNotFound
    end

    def paginated
      paginate(Project.all)
      head :ok
    end
  end

  before { allow(controller).to receive(:require_authentication) }

  it "names the version on every response" do
    get :index

    expect(response.headers["API-Version"]).to eq("v1")
    expect(response.headers).not_to include("Deprecation", "Sunset")
  end

  it "names the version on errors too, where clients most need it" do
    get :show, params: { id: 1 }

    expect(response).to have_http_status(:not_found)
    expect(response.headers["API-Version"]).to eq("v1")
  end

  it "names the version even when authentication fails" do
    allow(controller).to receive(:require_authentication).and_call_original

    get :index

    expect(response).to have_http_status(:unauthorized)
    expect(response.headers["API-Version"]).to eq("v1")
  end

  context "when the version is deprecated" do
    before do
      controller.class.deprecate_api! on: Date.new(2026, 12, 1), sunset: Date.new(2027, 6, 1),
                                      successor: "https://docs.example.test/v2"
    end

    after { controller.class.api_deprecation = nil }

    it "announces it with Deprecation, Sunset and a successor link, keeping pagination links" do
      get :index

      expect(response.headers["Deprecation"]).to eq("@#{Time.utc(2026, 12, 1).to_i}")
      expect(response.headers["Sunset"]).to eq("Tue, 01 Jun 2027 00:00:00 GMT")
      expect(response.headers["Link"]).to eq(
        '<https://docs.example.test/v2>; rel="successor-version", <https://example.test/page2>; rel="next"'
      )
    end

    it "keeps the successor link when the response is paginated, instead of letting pagination overwrite it" do
      create_list(:project, 3)
      routes.draw { get "paginated" => "api/v1/base#paginated" }

      get :paginated, params: { limit: 1 }

      links = response.headers["Link"]
      expect(links).to include('rel="successor-version"', 'rel="next"', 'rel="last"')
    end

    it "announces it on errors as well" do
      get :show, params: { id: 1 }

      expect(response).to have_http_status(:not_found)
      expect(response.headers).to include("Deprecation", "Sunset")
    end
  end
end
