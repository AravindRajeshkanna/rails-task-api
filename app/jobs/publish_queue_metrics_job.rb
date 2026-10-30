# Once a minute, writes the Solid Queue backlog as CloudWatch EMF log lines (when METRICS_EMF=true).
# CloudWatch anomaly detection and the autoscaling/alerting alarms read these series
# (namespace TaskApi: QueueDepth, OldestJobAgeSeconds, FailedJobs, and the event outbox's OutboxPending and
# OutboxOldestAgeSeconds). See deploy/terraform.
class PublishQueueMetricsJob < ApplicationJob
  queue_as :critical

  def perform
    return unless ENV["METRICS_EMF"] == "true"

    snapshot = Observability::QueueStats.snapshot or return
    environment = ENV.fetch("APP_ENV", Rails.env)

    snapshot.ready.each do |queue, depth|
      Rails.logger.info(Observability::Emf.record(
        dimensions: { "Environment" => environment, "Queue" => queue },
        metrics: { "QueueDepth" => [ depth, "Count" ], "OldestJobAgeSeconds" => [ snapshot.oldest_age.fetch(queue, 0), "Seconds" ] }
      ))
    end

    outbox_oldest = OutboxEvent.pending.minimum(:created_at)
    Rails.logger.info(Observability::Emf.record(
      dimensions: { "Environment" => environment },
      metrics: {
        "QueueDepth" => [ snapshot.total_ready, "Count" ], "OldestJobAgeSeconds" => [ snapshot.max_age, "Seconds" ],
        "FailedJobs" => [ snapshot.failed, "Count" ], "Workers" => [ snapshot.workers, "Count" ],
        "OutboxPending" => [ OutboxEvent.pending.count, "Count" ],
        "OutboxOldestAgeSeconds" => [ outbox_oldest ? (Time.current - outbox_oldest).to_i : 0, "Seconds" ]
      }
    ))
  end
end
