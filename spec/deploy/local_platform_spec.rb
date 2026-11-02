require "rails_helper"
require "yaml"

# What running docker compose and kind for the first time found (docs/local-platform.md), held in place. These read the files:
# the proof that the platform works is deploy/local/verify.sh against a running stack, which no spec can start.
RSpec.describe "The local platform's files" do
  let(:compose) { YAML.safe_load_file(Rails.root.join("docker-compose.yml"), aliases: true) }
  let(:services) { compose.fetch("services") }
  let(:up_script) { Rails.root.join("deploy/local/up.sh").read }

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

    it "gives the services that encrypt with Rails' own keys the setting that says so (there is no KMS here)" do
      expect(services.fetch("api").dig("environment", "ENCRYPTION_KEY_SOURCE")).to eq("credentials")
    end
  end

  describe "deploy/local/up.sh" do
    it "installs the kind build of ingress-nginx at a fixed version, which runs on the node that kind forwards port 8080 to" do
      manifest = up_script[/^INGRESS_MANIFEST=(\S+)/, 1]

      expect(manifest).to match(%r{\Ahttps://raw\.githubusercontent\.com/kubernetes/ingress-nginx/controller-v\d+\.\d+\.\d+/deploy/static/provider/kind/deploy\.yaml\z})
      expect(up_script).to include('kubectl apply -f "$INGRESS_MANIFEST"')
      expect(up_script).not_to include("kind.sigs.k8s.io/examples/ingress")
    end

    it "labels the control-plane node the way that manifest selects, and forwards the host port to it" do
      config = YAML.safe_load_file(Rails.root.join("deploy/local/kind-cluster.yaml"))
      control_plane = config["nodes"].find { |node| node["role"] == "control-plane" }

      expect(control_plane.to_json).to include("ingress-ready=true")
      expect(control_plane["extraPortMappings"]).to include(a_hash_including("containerPort" => 80, "hostPort" => 8080))
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
