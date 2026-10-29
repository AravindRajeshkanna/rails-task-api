module Observability
  # CloudWatch Embedded Metric Format: a structured log line that CloudWatch Logs turns into metrics,
  # with no agent, API call or IAM permission beyond shipping logs. Used for the few series CloudWatch
  # anomaly detection and alarms need (queue depth and latency); everything else lives in Prometheus.
  # https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch_Embedded_Metric_Format_Specification.html
  module Emf
    NAMESPACE = "TaskApi"

    module_function

    # +dimensions+: { "Environment" => "production", "Queue" => "default" }
    # +metrics+:    { "QueueDepth" => [ 12, "Count" ] }
    def record(dimensions:, metrics:, namespace: NAMESPACE, now: Time.current)
      {
        _aws: {
          Timestamp: (now.to_f * 1000).to_i,
          CloudWatchMetrics: [ {
            Namespace: namespace,
            Dimensions: [ dimensions.keys ],
            Metrics: metrics.map { |name, (_value, unit)| { Name: name, Unit: unit } }
          } ]
        }
      }.merge(dimensions).merge(metrics.transform_values(&:first))
    end
  end
end
