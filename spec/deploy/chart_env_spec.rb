require "rails_helper"
require "open3"
require "yaml"

# What the chart renders for each release, read as a cluster would read it. Helm 4 applies server-side, which refuses a
# container that lists one environment variable twice: the api release's migration Job (the template added SKIP_DB_PREPARE
# to the one the values already set) failed `deploy/local/up.sh` with "duplicate entries for key [name=\"SKIP_DB_PREPARE\"]".
# Client-side apply is generally said to let the later entry win; either way a name listed twice is a mistake.
RSpec.describe "The Helm chart's environment variables" do
  let(:chart) { Rails.root.join("deploy/helm/taskapi-service") }
  let(:releases) { Dir[Rails.root.join("deploy/helm/values/*.yaml").to_s].map { |file| File.basename(file, ".yaml") }.sort }

  before { skip "helm is not installed" unless system("helm", "version", out: File::NULL, err: File::NULL) }

  def render(release)
    output, status = Open3.capture2e("helm", "template", release, chart.to_s, "-f", Rails.root.join("deploy/helm/values/#{release}.yaml").to_s,
                                     "--set", "image.repository=x", "--set", "image.tag=y")
    raise output unless status.success?

    YAML.load_stream(output).compact
  end

  def pod_spec(document) = document.dig("spec", "template", "spec")

  def env_of(document, container = nil)
    containers = pod_spec(document)["containers"]
    (container ? containers.find { |entry| entry["name"] == container } : containers.first)["env"].to_h { |entry| [ entry["name"], entry["value"] ] }
  end

  it "has every release in the list, so a new one cannot escape the check" do
    expect(releases).to include("api", "worker", "auth", "ai", "notifications")
  end

  it "never lists a variable twice in any container of any release" do
    repeated = releases.flat_map do |release|
      render(release).filter_map { |document| pod_spec(document) }.flat_map do |pod|
        pod["containers"].filter_map do |container|
          names = (container["env"] || []).map { |entry| entry["name"] }
          "#{release}/#{container['name']}: #{names.tally.select { |_, count| count > 1 }.keys.join(', ')}" if names.uniq.size != names.size
        end
      end
    end

    expect(repeated).to be_empty
  end

  describe "SKIP_DB_PREPARE" do
    let(:documents) { render("api") }
    let(:migration_job) { documents.find { |document| document["kind"] == "Job" } }
    let(:web) { documents.find { |document| %w[Deployment Rollout].include?(document["kind"]) } }

    it "is false in the Job that migrates, once" do
      entries = pod_spec(migration_job)["containers"].first["env"].select { |entry| entry["name"] == "SKIP_DB_PREPARE" }

      expect(entries).to eq([ { "name" => "SKIP_DB_PREPARE", "value" => "false" } ])
    end

    it "stays true in the pods that serve, which must not migrate at boot" do
      expect(env_of(web)["SKIP_DB_PREPARE"]).to eq("true")
    end

    it "keeps every other variable the release's values set in the Job" do
      from_values = YAML.safe_load_file(Rails.root.join("deploy/helm/values/api.yaml"), aliases: true).fetch("env").transform_values(&:to_s).except("SKIP_DB_PREPARE")

      expect(env_of(migration_job)).to include(from_values)
    end
  end
end
