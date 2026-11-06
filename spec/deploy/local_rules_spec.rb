require "rails_helper"
require "open3"

# Two of the Grafana dashboard's twenty queries are recording rules (taskapi:http_error_ratio:rate5m, taskapi:queue_oldest_ready_age_seconds:max), which only
# the Kubernetes PrometheusRule defined: on docker compose, whose Prometheus loaded no rules, those panels were empty, and nothing said why. The rules compose
# loads are made from the same two PrometheusRule files by deploy/scripts/render_local_rules.rb; these examples keep the file, the Prometheus config, the
# mount and the dashboard in step.
RSpec.describe "The Prometheus rules on docker compose" do
  let(:root) { Rails.root }
  let(:local_rules) { YAML.safe_load_file(root.join("deploy/docker/prometheus-rules-local.yml")) }
  let(:recorded) { local_rules.fetch("groups").flat_map { |group| group["rules"] }.filter_map { |rule| rule["record"] } }

  def dashboard_expressions(panels)
    panels.flat_map { |panel| Array(panel["targets"]).filter_map { |target| target["expr"] } + dashboard_expressions(panel.fetch("panels", [])) }
  end

  it "is what the script makes from the PrometheusRule files, so that the two cannot drift" do
    printed, status = Open3.capture2e("ruby", root.join("deploy/scripts/render_local_rules.rb").to_s)

    expect(status).to be_success, printed
    expect(root.join("deploy/docker/prometheus-rules-local.yml").read).to eq(printed),
      "run: ruby deploy/scripts/render_local_rules.rb > deploy/docker/prometheus-rules-local.yml"
  end

  it "carries every rule Kubernetes applies, recording rules and alerts" do
    kubernetes = %w[task-api-rules task-api-slo].flat_map do |name|
      YAML.safe_load_file(root.join("deploy/observability/prometheus/#{name}.yaml")).dig("spec", "groups").flat_map { |group| group["rules"] }
    end

    expect(local_rules.fetch("groups").flat_map { |group| group["rules"] }).to eq(kubernetes)
    expect(recorded).to include("taskapi:http_error_ratio:rate5m", "taskapi:queue_oldest_ready_age_seconds:max")
  end

  it "is loaded by the Prometheus compose runs, from where compose puts it" do
    prometheus = YAML.safe_load_file(root.join("deploy/docker/prometheus-local.yml"))
    compose = YAML.safe_load_file(root.join("docker-compose.yml"), aliases: true)
    mounts = compose.dig("services", "prometheus", "volumes")

    expect(prometheus["rule_files"]).to eq([ "/etc/prometheus/rules.yml" ])
    expect(mounts).to include("./deploy/docker/prometheus-rules-local.yml:/etc/prometheus/rules.yml:ro")
  end

  it "defines every recording rule the dashboard reads" do
    dashboard = JSON.parse(root.join("deploy/observability/grafana/task-api-dashboard.json").read)
    series = dashboard_expressions(dashboard.fetch("panels")).flat_map { |expression| expression.scan(/\b[a-z_]+(?::[a-z0-9_]+)+\b/) }.uniq

    expect(series).not_to be_empty
    expect(series - recorded).to be_empty
  end
end
