# Once a minute, writes the Solid Queue backlog as CloudWatch EMF log lines (when METRICS_EMF=true).
# CloudWatch anomaly detection and the autoscaling/alerting alarms read these series
# (namespace TaskApi: QueueDepth, OldestJobAgeSeconds, FailedJobs). See deploy/terraform.
class PublishQueueMetricsJob < ApplicationJob
  queue_as :default

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

    Rails.logger.info(Observability::Emf.record(
      dimensions: { "Environment" => environment },
      metrics: {
        "QueueDepth" => [ snapshot.total_ready, "Count" ], "OldestJobAgeSeconds" => [ snapshot.max_age, "Seconds" ],
        "FailedJobs" => [ snapshot.failed, "Count" ], "Workers" => [ snapshot.workers, "Count" ]
      }
    ))
  end
end
