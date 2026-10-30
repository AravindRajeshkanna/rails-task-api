require "rails_helper"

RSpec.describe "CloudWatch EMF" do
  it "builds a valid Embedded Metric Format record" do
    record = Observability::Emf.record(
      dimensions: { "Environment" => "production", "Queue" => "default" },
      metrics: { "QueueDepth" => [ 12, "Count" ], "OldestJobAgeSeconds" => [ 3.2, "Seconds" ] },
      now: Time.utc(2026, 10, 29, 12, 0, 0)
    )

    expect(record).to eq(
      _aws: {
        Timestamp: 1_793_275_200_000,
        CloudWatchMetrics: [ {
          Namespace: "TaskApi", Dimensions: [ %w[Environment Queue] ],
          Metrics: [ { Name: "QueueDepth", Unit: "Count" }, { Name: "OldestJobAgeSeconds", Unit: "Seconds" } ]
        } ]
      },
      "Environment" => "production", "Queue" => "default", "QueueDepth" => 12, "OldestJobAgeSeconds" => 3.2
    )
  end

  describe PublishQueueMetricsJob do
    around do |example|
      ENV["METRICS_EMF"] = "true"
      ENV["APP_ENV"] = "production"
      example.run
    ensure
      ENV.delete("METRICS_EMF")
      ENV.delete("APP_ENV")
    end

    it "writes one record per queue plus a total, as JSON log lines" do
      with_solid_queue_tables
      enqueue_on_solid_queue(described_class, queue: "default")
      enqueue_on_solid_queue(described_class, queue: "default")
      lines = logged_emf_lines { described_class.perform_now }

      per_queue, total = lines.partition { |line| line["Queue"] }
      expect(per_queue.sole).to include("Environment" => "production", "Queue" => "default", "QueueDepth" => 2)
      expect(total.sole).to include("Environment" => "production", "QueueDepth" => 2, "FailedJobs" => 0, "Workers" => 0, "OutboxPending" => 0, "OutboxOldestAgeSeconds" => 0)
      expect(total.sole[:_aws][:CloudWatchMetrics].sole[:Dimensions]).to eq([ [ "Environment" ] ])
      expect(JSON.parse(JsonLogFormatter.new.call("INFO", Time.now, nil, total.sole))).to have_key("_aws") # reaches the log as top-level JSON
    end

    it "reports the event outbox backlog and the age of its oldest event for the alarm" do
      with_solid_queue_tables
      OutboxEvent.create!(event_id: "stuck", event_type: "task.created", payload: {}, created_at: 7.minutes.ago)

      total = logged_emf_lines { described_class.perform_now }.find { |line| !line["Queue"] }

      expect(total).to include("OutboxPending" => 1)
      expect(total["OutboxOldestAgeSeconds"]).to be_between(419, 421)
    end

    it "does nothing unless enabled, or without queue tables" do
      ENV.delete("METRICS_EMF")
      expect(logged_emf_lines { described_class.perform_now }).to be_empty

      ENV["METRICS_EMF"] = "true"
      expect(logged_emf_lines { described_class.perform_now }).to be_empty # no queue tables in the test database
    end

    # Only the EMF records: the event log subscriber also writes to Rails.logger.
    def logged_emf_lines
      lines = []
      allow(Rails.logger).to receive(:info) { |line| lines << line }
      yield
      lines.select { |line| line.is_a?(Hash) && line.key?(:_aws) }
    end
  end
end
