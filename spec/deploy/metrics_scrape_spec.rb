require "rails_helper"
require "open3"

# The pod and the scraper have to agree. Observability::MetricsApp answers 403 to any scrape without METRICS_TOKEN once the pod has one, and the chart
# gives the pod one; a PodMonitor that does not send it gets 403 on every scrape, every taskapi_* metric goes missing, and (because absent data cannot
# page) the SLO alerts say nothing. Rendering the chart and validating its schema (CI) could not see this; it is a disagreement between two files.
RSpec.describe "Metrics scrape configuration" do
  let(:chart) { Rails.root.join("deploy/helm/taskapi-service") }
  let(:releases) { Dir[Rails.root.join("deploy/helm/values/*.yaml").to_s].to_h { |file| [ File.basename(file, ".yaml"), YAML.safe_load_file(file, aliases: true) ] } }

  def demands_token?(values) = Array(values.dig("secrets", "data")).any? { |entry| entry["secretKey"] == "METRICS_TOKEN" }

  it "has the scraper send the token to every release whose pods demand one" do
    demanding = releases.select { |_, values| demands_token?(values) }

    expect(demanding.keys).not_to be_empty
    demanding.each do |name, values|
      expect(values.dig("metrics", "tokenSecret")).to include("key" => "METRICS_TOKEN", "name" => be_present),
        "#{name} gives its pods METRICS_TOKEN, so its PodMonitor must send it (metrics.tokenSecret)"
    end
  end

  it "names, for the token, the Secret that the same release's pods read it from" do
    secret_names = { "api" => "api" } # the ExternalSecret is named after the release; envFrom reads it by that name
    releases.select { |_, values| demands_token?(values) }.each do |name, values|
      expect(values.dig("metrics", "tokenSecret", "name")).to eq(secret_names.fetch(name))
    end
  end

  describe "the rendered PodMonitor" do
    before { skip "helm is not installed" unless system("helm", "version", out: File::NULL, err: File::NULL) }

    def pod_monitor_endpoint(release)
      output, status = Open3.capture2e("helm", "template", release, chart.to_s, "-f", Rails.root.join("deploy/helm/values/#{release}.yaml").to_s,
                                       "--set", "image.repository=x", "--set", "image.tag=y")
      raise output unless status.success?

      YAML.load_stream(output).compact.find { |document| document["kind"] == "PodMonitor" }.dig("spec", "podMetricsEndpoints").sole
    end

    it "sends the bearer token the API demands" do
      expect(pod_monitor_endpoint("api")["authorization"]).to eq("type" => "Bearer", "credentials" => { "name" => "api", "key" => "METRICS_TOKEN" })
    end

    it "sends nothing for a release that demands none" do
      expect(pod_monitor_endpoint("ai")).not_to have_key("authorization")
    end
  end
end
