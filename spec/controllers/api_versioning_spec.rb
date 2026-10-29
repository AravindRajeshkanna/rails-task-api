require "rails_helper"

RSpec.describe ApiVersioning, type: :controller do
  controller(Api::V1::BaseController) do
    skip_after_action :verify_authorized
    skip_after_action :verify_policy_scoped, raise: false

    def index
      response.headers["Link"] = '<https://example.test/page2>; rel="next"'
      head :ok
    end
  end

  before { allow(controller).to receive(:require_authentication) }

  it "names the version on every response" do
    get :index

    expect(response.headers["API-Version"]).to eq("v1")
    expect(response.headers).not_to include("Deprecation", "Sunset")
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
        '<https://example.test/page2>; rel="next", <https://docs.example.test/v2>; rel="successor-version"'
      )
    end
  end
end
