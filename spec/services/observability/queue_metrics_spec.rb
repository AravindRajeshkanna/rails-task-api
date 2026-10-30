require "rails_helper"

RSpec.describe "Queue metrics" do
  describe Observability::QueueStats do
    it "is nil where the queue tables do not exist (development, test)" do
      expect(described_class.snapshot).to be_nil
    end

    it "reports backlog, queue latency and failures from Solid Queue's tables" do
      with_solid_queue_tables
      travel_to(Time.utc(2026, 10, 29, 12, 0, 0)) do
        enqueue_on_solid_queue(PublishQueueMetricsJob, queue: "default")
        enqueue_on_solid_queue(PublishQueueMetricsJob, queue: "default")
        enqueue_on_solid_queue(PublishQueueMetricsJob, queue: "mailers")
        enqueue_on_solid_queue(PublishQueueMetricsJob, queue: "later", wait: 1.hour)
        travel 90.seconds

        snapshot = described_class.snapshot

        expect(snapshot.ready).to eq("default" => 2, "mailers" => 1)
        expect(snapshot.total_ready).to eq(3)
        expect(snapshot.oldest_age).to eq("default" => 90.0, "mailers" => 90.0)
        expect(snapshot.max_age).to eq(90.0)
        expect(snapshot).to have_attributes(scheduled: 1, failed: 0, claimed: 0, workers: 0)
      end
    end
  end

  describe Observability::Collector do
    before { described_class.reset! }

    it "sets the gauges and zeroes queues that drained" do
      with_solid_queue_tables
      enqueue_on_solid_queue(PublishQueueMetricsJob, queue: "default")
      described_class.refresh!(now: 0)
      expect(Observability::Metrics::QUEUE_READY.get(labels: { queue: "default" })).to eq(1)

      SolidQueue::ReadyExecution.delete_all
      described_class.refresh!(now: 100)

      expect(Observability::Metrics::QUEUE_READY.get(labels: { queue: "default" })).to eq(0)
    end

    it "reports the event outbox: how many are waiting, how old the oldest is, how many have failed" do
      travel_to(Time.utc(2026, 10, 29, 12, 0, 0)) do
        make = ->(**attributes) { OutboxEvent.create!(event_id: SecureRandom.uuid, event_type: "task.created", payload: {}, **attributes) }
        make.call(created_at: 90.seconds.ago, attempts: 3)
        make.call(created_at: 10.seconds.ago)
        make.call(created_at: 5.minutes.ago, published_at: 4.minutes.ago) # delivered: not waiting

        described_class.refresh!(now: 0)

        expect(Observability::Metrics::OUTBOX_PENDING.get).to eq(2)
        expect(Observability::Metrics::OUTBOX_OLDEST_AGE.get).to eq(90)
        expect(Observability::Metrics::OUTBOX_FAILING.get).to eq(1)

        OutboxEvent.delete_all
        described_class.reset!
        described_class.refresh!(now: 100)
        expect(Observability::Metrics::OUTBOX_OLDEST_AGE.get).to eq(0)
      end
    end

    it "does not query again within the TTL" do
      described_class.refresh!(now: 0)

      expect(Observability::QueueStats).not_to receive(:snapshot)
      described_class.refresh!(now: described_class::TTL - 1)
    end

    it "reports the connection pool" do
      described_class.refresh!(now: 0)

      expect(Observability::Metrics::DB_POOL.get(labels: { state: "size" })).to be_positive
    end

    it "counts a failing collector instead of failing the scrape" do
      allow(Observability::QueueStats).to receive(:snapshot).and_raise(ActiveRecord::StatementInvalid, "boom")

      expect { described_class.refresh!(now: 0) }.to change { Observability::Metrics::COLLECTOR_ERRORS.get(labels: { collector: "queue" }) }.by(1)
    end
  end
end
