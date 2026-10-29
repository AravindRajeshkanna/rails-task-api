require "spec_helper"
require_relative "support"
require "aiops/evidence"
require "aiops/k8s"

RSpec.describe Aiops::Evidence do
  ENV["AIOPS_NO_SLEEP"] = "1"

  let(:logs) { Aws::CloudWatchLogs::Client.new(stub_responses: true, region: "us-east-1") }
  let(:cloudwatch) { Aws::CloudWatch::Client.new(stub_responses: true, region: "us-east-1") }
  let(:xray) { Aws::XRay::Client.new(stub_responses: true, region: "us-east-1") }
  let(:now) { Time.utc(2026, 10, 29, 12, 0, 0) }
  let(:alarm) { Aiops::Alarm.from_sns(alarm_event(name: "task-api-prod-queue-latency")) }
  let(:k8s) { FakeK8s.new("/apis/apps/v1/namespaces/task-api/replicasets" => { "items" => [] }) }

  def evidence(k8s: self.k8s) = described_class.new(environment: "prod", cluster: "c", log_group: "lg", k8s: k8s, logs: logs, cloudwatch: cloudwatch, xray: xray)

  it "gathers error groups, firing alarms, deploys and traces" do
    cloudwatch.stub_responses(:describe_alarms, metric_alarms: [ { alarm_name: "task-api-prod-queue-latency" }, { alarm_name: "task-api-prod-error-rate-anomaly" } ])
    logs.stub_responses(:start_query, query_id: "q1")
    logs.stub_responses(:get_query_results, status: "Complete", results: [ [ { field: "controller", value: "Api::V1::TasksController" }, { field: "errors", value: "41" }, { field: "@ptr", value: "x" } ] ])
    k8s.get("/apis/apps/v1/namespaces/task-api/replicasets")["items"] << {
      "metadata" => { "creationTimestamp" => (now - 420).iso8601, "ownerReferences" => [ { "name" => "worker" } ] },
      "spec" => { "template" => { "spec" => { "containers" => [ { "image" => "1234.dkr.ecr.us-east-1.amazonaws.com/task-api/api:abc1234" } ] } } }
    }
    xray.stub_responses(:get_trace_summaries, trace_summaries: [ { id: "1-abc-def", duration: 4.2, has_fault: true, http: { http_url: "https://api/x?token=SECRET" } } ])

    result = evidence.collect(alarm, now: now)

    expect(result["other_alarms_firing"]).to eq([ "task-api-prod-error-rate-anomaly" ])
    expect(result["error_groups_5xx"]).to eq([ { "controller" => "Api::V1::TasksController", "errors" => "41" } ])
    expect(result["recent_deploys"]).to eq([ { "workload" => "worker", "image" => "api:abc1234", "minutes_ago" => 7 } ])
    expect(result["slow_or_faulty_traces"].first).to include("id" => "1-abc-def", "fault" => true, "http" => "https://api/x")
  end

  it "keeps going when one source fails, and says which" do
    cloudwatch.stub_responses(:describe_alarms, "AccessDenied")
    logs.stub_responses(:start_query, "ResourceNotFoundException")
    xray.stub_responses(:get_trace_summaries, trace_summaries: [])

    result = evidence.collect(alarm, now: now)

    expect(result["other_alarms_firing"]).to eq("unavailable (other_alarms_firing: AccessDenied)")
    expect(result["error_groups_5xx"]).to eq("unavailable (error_groups_5xx: ResourceNotFoundException)")
    expect(result["slow_or_faulty_traces"]).to eq("none found")
    expect(result["recent_deploys"]).to eq("none found")
  end

  it "does not need cluster access" do
    expect(evidence(k8s: nil).collect(alarm, now: now)["recent_deploys"]).to eq("unavailable (no cluster access configured)")
  end

  it "queries the app's JSON logs for 5xx by controller action over the last 15 minutes" do
    logs.stub_responses(:start_query, query_id: "q")
    logs.stub_responses(:get_query_results, status: "Complete", results: [])

    evidence.collect(alarm, now: now)

    request = logs.api_requests.find { |entry| entry[:operation_name] == :start_query }[:params]
    expect(request).to include(log_group_name: "lg", start_time: (now - 900).to_i, end_time: now.to_i)
    expect(request[:query_string]).to include("status >= 500", "stats count(*) as errors by controller, action")
  end
end

RSpec.describe Aiops::K8s do
  it "authenticates like `aws eks get-token`: a presigned STS URL that names the cluster" do
    eks = Aws::EKS::Client.new(stub_responses: true, region: "us-east-1")
    credentials = Aws::Credentials.new("AKIAEXAMPLE", "secret", "session")
    token = described_class.new(cluster: "task-api-prod", region: "us-east-1", eks: eks, credentials: credentials).token(now: Time.utc(2026, 10, 29, 12))

    expect(token).to start_with("k8s-aws-v1.")
    padded = token.delete_prefix("k8s-aws-v1.")
    url = Base64.urlsafe_decode64(padded + "=" * (-padded.length % 4))
    expect(url).to start_with("https://sts.us-east-1.amazonaws.com/?Action=GetCallerIdentity")
    expect(url).to include("X-Amz-Expires=60", "x-k8s-aws-id")
  end
end
