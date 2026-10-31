require "rails_helper"

# Liveness and readiness are different questions (ADR 63): restart the pod, or just stop sending it traffic.
RSpec.describe "Health checks" do
  describe "GET /livez" do
    it "says the process is alive, to anyone, without touching the database" do
      expect(ActiveRecord::Base).not_to receive(:connection_pool)

      get "/livez"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("status" => "ok", "checks" => {})
      expect(response.headers["Cache-Control"]).to include("no-store")
    end

    it "stays alive when the database is down, because restarting every API pod does not bring a database back" do
      allow(ActiveRecord::Base).to receive(:connection_pool).and_raise(ActiveRecord::ConnectionNotEstablished)

      get "/livez"

      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /readyz" do
    it "says it can serve when the database answers" do
      get "/readyz"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("status" => "ok", "checks" => { "database" => "ok", "encryption" => "ok" })
    end

    it "says it cannot when the database does not, so the pod is taken out of rotation, and gives away nothing about why" do
      allow(ActiveRecord::Base).to receive(:connection_pool).and_raise(PG::ConnectionBad, "could not connect to server at 10.0.3.14: Connection refused")

      get "/readyz"

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body).to eq("status" => "unavailable", "checks" => { "database" => "failed", "encryption" => "ok" })
      expect(response.body).not_to include("10.0.3.14", "Connection refused")
    end

    it "does not wait for a database that is hanging: it gives up after a couple of seconds" do
      allow(ActiveRecord::Base).to receive(:connection_pool).and_wrap_original { |original| sleep 5; original.call }
      stub_const("HealthController::DATABASE_TIMEOUT", 0.2)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      get "/readyz"

      expect(response).to have_http_status(:service_unavailable)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1.5
    end

    it "says it cannot while it has no encryption keys, so a rollout with a bad KMS setting waits instead of serving errors, and says nothing about the setting" do
      allow(KmsEncryption).to receive(:ready?).and_return(false)

      get "/readyz"

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body).to eq("status" => "unavailable", "checks" => { "database" => "ok", "encryption" => "failed" })
      expect(response.body).not_to include("KMS_KEY_ID", "AccessDenied")
    end

    it "does not wait on a KMS that is hanging: it gives up and reports not ready" do
      allow(KmsEncryption).to receive(:ready?) { sleep 5 }
      stub_const("HealthController::ENCRYPTION_TIMEOUT", 0.2)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      get "/readyz"

      expect(response).to have_http_status(:service_unavailable)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1.5
    end

    it "needs no sign-in" do
      get "/readyz", headers: { "Authorization" => "Bearer nonsense" }

      expect(response).to have_http_status(:ok)
    end
  end

  it "keeps /up as it was, for Kamal and anything that already uses it" do
    get "/up"

    expect(response).to have_http_status(:ok)
  end

  it "exempts all of them from the host check in production, because probes reach a pod by its IP" do
    production = Rails.root.join("config/environments/production.rb").read

    expect(production).to match(%r{host_authorization.*%w\[/up /livez /readyz /metrics\]})
  end

  it "is what the platform asks: readiness for traffic and the failover check, liveness for restarts" do
    values = YAML.safe_load_file(Rails.root.join("deploy/helm/values/api.yaml"), aliases: true)
    edge = Rails.root.join("deploy/terraform/edge.tf").read

    expect(values.fetch("probes")).to include("path" => "/readyz", "livenessPath" => "/livez")
    expect(values.dig("ingress", "annotations", "alb.ingress.kubernetes.io/healthcheck-path")).to eq("/readyz")
    expect(edge).to include('resource_path     = "/readyz"')
  end
end
