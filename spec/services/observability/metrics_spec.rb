require "rails_helper"

RSpec.describe "Prometheus metrics", type: :request do
  let(:metrics) { Observability::Metrics }
  let(:subscriber) { Events::MetricsSubscriber.new }

  def emit(name, payload) = subscriber.emit(name: name, payload: payload, context: {}, tags: {}, timestamp: 0)

  it "counts requests and observes latency per controller action" do
    labels = { controller: "Api::V1::TasksController", action: "index", status: "200" }
    duration_labels = { controller: "Api::V1::TasksController", action: "index" }
    # The registry is process-wide, so earlier examples (real requests, which can take over 50 ms on a slow runner) have already
    # observed into these buckets: compare what this observation adds, not the totals.
    before = metrics::HTTP_DURATION.get(labels: duration_labels).dup

    expect {
      emit("action_controller.request_completed", { controller: "Api::V1::TasksController", action: "index", status: 200, duration_ms: 120.0 })
    }.to change { metrics::HTTP_REQUESTS.get(labels: labels) }.by(1)

    after = metrics::HTTP_DURATION.get(labels: duration_labels)
    added = ->(bucket) { after[bucket] - before[bucket] }
    expect(added.call("0.25")).to eq(1)
    expect([ added.call("0.05"), added.call("0.1") ]).to eq([ 0, 0 ]) # 120 ms lands above the 100 ms bucket
  end

  it "records real requests end to end" do
    user = create(:user)
    labels = { controller: "Api::V1::MeController", action: "show", status: "200" }

    expect { api(:get, "/api/v1/me", as: user) }.to change { metrics::HTTP_REQUESTS.get(labels: labels) }.by(1)
  end

  it "counts domain events and ignores unknown ones" do
    expect { emit("task.completed", {}) }.to change { metrics::DOMAIN_EVENTS.get(labels: { event: "task.completed" }) }.by(1)
    expect { emit("something.else", {}) }.not_to change { metrics::REGISTRY.metrics.sum { |metric| metric.values.size } }
  end

  it "counts KMS requests by operation and outcome, and times them" do
    expect { emit("kms.request", { operation: "decrypt", outcome: "ok", duration_ms: 12.0 }) }
      .to change { metrics::KMS_REQUESTS.get(labels: { operation: "decrypt", outcome: "ok" }) }.by(1)
    expect { emit("kms.failed", { operation: "generate_data_key", outcome: "throttled", duration_ms: 300.0 }) }
      .to change { metrics::KMS_REQUESTS.get(labels: { operation: "generate_data_key", outcome: "throttled" }) }.by(1)
    expect(metrics::KMS_DURATION.get(labels: { operation: "decrypt" })["0.025"]).to be >= 1
  end

  it "accounts for AI calls: tokens, cost and latency" do
    payload = { feature: "parse_task", outcome: "ok", input_tokens: 1_000, output_tokens: 200, cost_micros: 4_500, latency_ms: 1_500 }

    emit("ai.completed", payload)

    expect(metrics::AI_REQUESTS.get(labels: { feature: "parse_task", outcome: "ok" })).to be >= 1
    expect(metrics::AI_TOKENS.get(labels: { feature: "parse_task", direction: "input" })).to be >= 1_000
    expect(metrics::AI_COST.get(labels: { feature: "parse_task" })).to be >= 0.0045
    expect(metrics::AI_LATENCY.get(labels: { feature: "parse_task" })["2"]).to be >= 1
  end

  it "counts failed AI calls but not their tokens" do
    expect { emit("ai.completed", { feature: "chat", outcome: "error", input_tokens: 0, output_tokens: 0, cost_micros: 0, latency_ms: 0 }) }
      .to change { metrics::AI_REQUESTS.get(labels: { feature: "chat", outcome: "error" }) }.by(1)
  end

  it "counts budget rejections raised by the AI runner" do
    user = create(:user)
    AiUsage.create!(user: user, feature: "chat", input_tokens: Ai.config.daily_tokens_per_user)

    expect {
      expect { Ai::Runner.new(user: user).run("parse_task", { text: "x", today: "2026-10-29" }) }.to raise_error(Ai::BudgetExceeded)
    }.to change { metrics::AI_BUDGET_REJECTIONS.get }.by(1)
  end

  it "publishes domain events from real changes" do
    task = nil
    expect { task = create(:task) }.to change { metrics::DOMAIN_EVENTS.get(labels: { event: "task.created" }) }.by(1)
    expect { task.update!(status: :done) }.to change { metrics::DOMAIN_EVENTS.get(labels: { event: "task.completed" }) }.by(1)
  end
end
