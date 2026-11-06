require "rails_helper"
require "yaml"

# What running docker compose and kind for the first time found (docs/local-platform.md), held in place. These read the files:
# the proof that the platform works is deploy/local/verify.sh against a running stack, which no spec can start.
RSpec.describe "The local platform's files" do
  let(:compose) { YAML.safe_load_file(Rails.root.join("docker-compose.yml"), aliases: true) }
  let(:services) { compose.fetch("services") }
  let(:up_script) { Rails.root.join("deploy/local/up.sh").read }
  let(:traefik_values) { YAML.safe_load_file(Rails.root.join("deploy/local/traefik-values.yaml")) }

  describe "docker-compose.yml" do
    it "builds each image once: services that share an image let one of them build it" do
      # Three services with a build section and one tag are exported at once; on the containerd image store (Docker Desktop's default)
      # the first `docker compose up --build` fails with `image "docker.io/task-api/api:local": already exists`.
      builders = services.select { |_, service| service.key?("build") }.group_by { |_, service| service["image"] }

      expect(builders.transform_values { |entries| entries.map(&:first) }.select { |_, names| names.size > 1 }).to be_empty
      expect(services.values_at("api", "migrate", "worker").map { |service| service["image"] }.uniq).to eq([ "task-api/api:local" ])
      expect(services["api"]).to have_key("build")
    end

    it "never pulls the shared image from a registry, for the services that only use it" do
      expect(services.values_at("migrate", "worker").map { |service| service["pull_policy"] }).to eq(%w[never never])
    end

    it "publishes no host port that macOS keeps (5000 and 7000 are the AirPlay Receiver's)" do
      host_ports = services.values.flat_map { |service| Array(service["ports"]) }.map { |mapping| mapping.to_s.split(":")[-2] }

      expect(host_ports).not_to include("5000", "7000")
    end

    it "publishes the stores and mocks on the loopback address only, not on every network the laptop is on" do
      exposed = %w[postgres aws mailpit otel-collector jaeger prometheus grafana].flat_map { |name| Array(services.fetch(name)["ports"]).map { |mapping| [ name, mapping ] } }
      open_to_the_network = exposed.reject { |_, mapping| mapping.to_s.start_with?("127.0.0.1:") }

      expect(exposed).not_to be_empty
      expect(open_to_the_network).to be_empty
    end

    it "restarts the Notification service when it exits: its consumer ends the process on a crash and expects an orchestrator to start it again" do
      expect(services.dig("notifications", "environment", "NOTIFICATIONS_CONSUMER")).to eq("true")
      expect(services.dig("notifications", "restart")).to eq("on-failure")
    end

    it "gives the services that encrypt with Rails' own keys the setting that says so (there is no KMS here)" do
      expect(services.fetch("api").dig("environment", "ENCRYPTION_KEY_SOURCE")).to eq("credentials")
    end
  end

  describe "deploy/local/up.sh" do
    it "installs Traefik from its chart at a fixed version, skipping the CRDs that nothing here uses, and no longer ingress-nginx (retired in March 2026)" do
      expect(up_script[/^TRAEFIK_CHART=(\S+)/, 1]).to eq("oci://ghcr.io/traefik/helm/traefik")
      expect(up_script[/^TRAEFIK_VERSION=(\S+)/, 1]).to match(/\A\d+\.\d+\.\d+\z/)
      expect(up_script).to include('helm upgrade --install traefik "$TRAEFIK_CHART" --version "$TRAEFIK_VERSION"')
      expect(up_script).to include("--skip-crds", "-f deploy/local/traefik-values.yaml", "--wait")
      expect(up_script.lines.reject { |line| line.strip.start_with?("#") }.join).not_to match(/ingress-nginx|kind\.sigs\.k8s\.io\/examples\/ingress/) # the comment says why it left
      expect(traefik_values.dig("providers", "kubernetesCRD", "enabled")).to be(false) # enabled, Traefik would watch for CRDs that were not installed
    end

    it "runs the controller on the node that kind forwards port 8080 to, on that node's port 80" do
      config = YAML.safe_load_file(Rails.root.join("deploy/local/kind-cluster.yaml"))
      control_plane = config["nodes"].find { |node| node["role"] == "control-plane" }

      expect(control_plane.to_json).to include("ingress-ready=true")
      expect(control_plane["extraPortMappings"]).to include(a_hash_including("containerPort" => 80, "hostPort" => 8080))
      expect(traefik_values["nodeSelector"]).to eq("ingress-ready" => "true")
      expect(traefik_values["tolerations"]).to include(a_hash_including("key" => "node-role.kubernetes.io/control-plane", "effect" => "NoSchedule"))
      expect(traefik_values.dig("ports", "web", "hostPort")).to eq(80)
    end

    it "updates the controller by stopping the old pod first: beside it the new one would wait for ever on the port, and `helm upgrade` with it" do
      strategy = traefik_values.fetch("updateStrategy")

      expect(strategy).to include("type" => "RollingUpdate")
      expect(strategy["rollingUpdate"]).to include("maxSurge" => 0, "maxUnavailable" => 1)
    end

    it "serves the class the releases ask for, and the one `ingress.className` names in the local values" do
      local = YAML.safe_load_file(Rails.root.join("deploy/local/values-local.yaml"))

      expect(traefik_values.dig("ingressClass", "name")).to eq("traefik")
      expect(local.dig("ingress", "className")).to eq("traefik")
      expect(up_script).not_to include("ingress.className") # one place says it
    end

    it "prints the controller's log without colour, for diagnose.sh to put in a CI log, from the namespace it is installed in" do
      expect(traefik_values.dig("log", "noColor")).to be(true)
      expect(Rails.root.join("deploy/local/diagnose.sh").read).to include("kubectl -n traefik logs deploy/traefik")
      expect(up_script).to include("-n traefik")
    end

    it "gives the monolith's two releases a key source, or /readyz fails and the pod never becomes ready" do
      monolith_loop = up_script[/for release in api worker; do.*?^done/m]

      expect(monolith_loop).to include('env.ENCRYPTION_KEY_SOURCE=credentials')
    end

    it "does not point the span exporter at a collector that is not there" do
      expect(up_script).to include('"env.OTEL_EXPORTER_OTLP_ENDPOINT="')
    end
  end

  describe "deploy/local/verify.sh" do
    let(:verify) { Rails.root.join("deploy/local/verify.sh") }

    it "is executable and parses under the bash that macOS ships (3.2)" do
      expect(verify).to be_executable
      expect(system("/bin/bash", "-n", verify.to_s)).to be(true)
    end

    it "asks only for paths that both the compose gateway and the kind Ingress route" do
      script = verify.read

      expect(script).not_to match(%r{call GET /(livez|readyz|up)\b})
      expect(script).to include("/api/v1/projects", "/api-docs/v1/swagger.yaml", "/api/v1/session", "/api/v1/registrations")
    end
  end
end
