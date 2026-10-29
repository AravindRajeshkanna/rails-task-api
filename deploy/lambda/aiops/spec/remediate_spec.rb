require "spec_helper"
require_relative "support"
require "aiops/remediate"

RSpec.describe Aiops::Remediate do
  let(:sns) { sns_client }
  let(:now) { Time.utc(2026, 10, 29, 12, 0, 0) }
  let(:scaled_object_path) { "/apis/keda.sh/v1alpha1/namespaces/task-api/scaledobjects/worker" }
  let(:deployment_path) { "/apis/apps/v1/namespaces/task-api/deployments/worker" }
  let(:env) { { "ENVIRONMENT" => "prod", "CLUSTER_NAME" => "task-api-prod", "AWS_REGION" => "us-east-1", "ALERTS_TOPIC_ARN" => "arn:aws:sns:us-east-1:1:alerts", "REMEDIATION_DRY_RUN" => "false" } }
  let(:k8s) { FakeK8s.new(scaled_object_path => { "metadata" => { "annotations" => {} }, "spec" => { "minReplicaCount" => 2, "maxReplicaCount" => 10 } }, deployment_path => { "spec" => { "template" => { "metadata" => {} } } }) }

  def run(name, state: "ALARM", env: self.env, at: now)
    alarm = Aiops::Alarm.from_sns(alarm_event(name: name, state: state))
    described_class.process(alarm, env: env, k8s: k8s, sns: sns, now: at)
  end

  describe "queue-backlog" do
    it "doubles KEDA's minimum worker count and remembers the original" do
      result = run("task-api-prod-queue-backlog")

      expect(result).to eq(action: "raise_worker_floor", from: 2, to: 4, applied: true)
      path, body = sole(k8s.patches)
      expect(path).to eq(scaled_object_path)
      expect(body[:spec]).to eq(minReplicaCount: 4)
      expect(body[:metadata][:annotations]).to include("aiops.taskapi.dev/original-min-replicas" => "2", "aiops.taskapi.dev/last-action-at" => now.iso8601)
    end

    it "never goes past the configured maximum" do
      k8s.get(scaled_object_path)["spec"]["minReplicaCount"] = 7

      expect(run("task-api-prod-queue-backlog")).to include(to: 10)
      expect(run("task-api-prod-queue-backlog", at: now + 3600)).to include(skipped: /already at the maximum/)
    end

    it "does not act twice within the cooldown" do
      run("task-api-prod-queue-backlog")

      expect(run("task-api-prod-queue-backlog", at: now + 5 * 60)).to eq(skipped: "cooling down")
      expect(k8s.patches.size).to eq(1)
      expect(run("task-api-prod-queue-backlog", at: now + 16 * 60)).to include(applied: true)
    end

    it "puts the original count back when the alarm recovers" do
      run("task-api-prod-queue-backlog")

      result = run("task-api-prod-queue-backlog", state: "OK", at: now + 30 * 60)

      expect(result).to eq(action: "restore_worker_floor", to: 2, applied: true)
      expect(k8s.get(scaled_object_path)["spec"]["minReplicaCount"]).to eq(2)
      expect(k8s.get(scaled_object_path)["metadata"]["annotations"]).not_to have_key("aiops.taskapi.dev/original-min-replicas")
    end

    it "has nothing to undo when it never acted" do
      expect(run("task-api-prod-queue-backlog", state: "OK")).to eq(skipped: "nothing to undo")
    end
  end

  describe "queue-latency" do
    it "restarts the workers with a rolling restart, once per cooldown" do
      expect(run("task-api-prod-queue-latency")).to eq(action: "restart_workers", applied: true)
      annotations = k8s.get(deployment_path).dig("spec", "template", "metadata", "annotations")
      expect(annotations).to include("kubectl.kubernetes.io/restartedAt" => now.iso8601)

      expect(run("task-api-prod-queue-latency", at: now + 60)).to eq(skipped: "cooling down")
    end

    it "does not restart anything when the alarm clears" do
      expect(run("task-api-prod-queue-latency", state: "OK")).to eq(skipped: "nothing to undo")
      expect(k8s.patches).to be_empty
    end
  end

  describe "guardrails" do
    it "is a dry run unless explicitly turned off: it reports and changes nothing" do
      result = run("task-api-prod-queue-backlog", env: env.except("REMEDIATION_DRY_RUN"))

      expect(result).to include(applied: false, to: 4)
      expect(k8s.patches).to be_empty
      message = sole(published(sns))
      expect(message[:message]).to start_with("[dry run] WOULD HAVE acted")
    end

    it "reports what it did to the on-call channel, marked so no Lambda re-processes it" do
      run("task-api-prod-queue-backlog")

      message = sole(published(sns))
      expect(message[:message]).to include("DID acted on task-api-prod-queue-backlog (ALARM)")
      expect(message[:message_attributes]["kind"][:string_value]).to eq("rca")
    end

    it "has no opinion about alarms outside the playbook" do
      expect(run("task-api-prod-database-near-max-capacity")).to eq(skipped: "no runbook for task-api-prod-database-near-max-capacity")
      expect(k8s.patches).to be_empty
      expect(published(sns)).to be_empty
    end

    it "only acts on alarms of its own environment" do
      expect(run("task-api-staging-queue-backlog")).to include(skipped: /no runbook/)
    end
  end

  it "handles the Lambda event" do
    expect(described_class.handler(event: alarm_event(message: "not json"))).to eq(skipped: "not an alarm")
  end
end
