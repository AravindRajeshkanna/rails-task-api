require "rails_helper"

RSpec.describe "GET /metrics" do
  let(:app) { Observability::MetricsApp.new(token: token) }
  let(:token) { nil }

  def scrape(headers = {}, ip: "10.1.2.3")
    status, response_headers, body = app.call(Rack::MockRequest.env_for("/metrics", { "REMOTE_ADDR" => ip }.merge(headers)))
    [ status, response_headers, body.join ]
  end

  it "serves the Prometheus text format, including this app's metrics" do
    emit_request = Events::MetricsSubscriber.new
    emit_request.emit(name: "action_controller.request_completed", payload: { controller: "X", action: "y", status: 200, duration_ms: 5 }, context: {}, tags: {}, timestamp: 0)

    status, headers, body = scrape

    expect(status).to eq(200)
    expect(headers["content-type"]).to start_with("text/plain; version=0.0.4")
    expect(body).to include("# TYPE taskapi_http_requests_total counter", 'taskapi_http_requests_total{controller="X",action="y",status="200"}')
    expect(body).to include("taskapi_db_pool_connections", "taskapi_build_info")
  end

  it "is mounted in the Rails router" do
    get "/metrics"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("taskapi_http_requests_total")
  end

  context "in production without a token" do
    before { allow(Rails.env).to receive(:production?).and_return(true) }

    it "serves private-network scrapers" do
      %w[10.0.4.7 172.16.0.9 192.168.1.5 127.0.0.1].each { |ip| expect(scrape(ip: ip).first).to eq(200) }
    end

    it "refuses public addresses, such as traffic arriving through the load balancer" do
      expect(scrape(ip: "203.0.113.9").first).to eq(403)
      expect(scrape({ "HTTP_X_FORWARDED_FOR" => "203.0.113.9" }, ip: "10.0.1.1").first).to eq(403)
    end
  end

  context "with a token" do
    let(:token) { "scrape-secret" }

    it "requires it, wherever the caller is" do
      expect(scrape({ "HTTP_AUTHORIZATION" => "Bearer scrape-secret" }, ip: "203.0.113.9").first).to eq(200)
      expect(scrape({ "HTTP_AUTHORIZATION" => "Bearer wrong" }).first).to eq(403)
      expect(scrape.first).to eq(403)
    end
  end
end
