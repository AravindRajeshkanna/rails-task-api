require "prometheus/client"
require "prometheus/client/formats/text"

module Observability
  # The Prometheus metrics this service exposes on /metrics. Counters and histograms are fed by
  # Events::MetricsSubscriber from Rails.event; gauges are refreshed at scrape time by Collector.
  #
  # Labels are deliberately low-cardinality (controller#action, status, feature): never a user or
  # record id, and never a raw path.
  module Metrics
    REGISTRY = Prometheus::Client.registry
    LATENCY_BUCKETS = [ 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10 ].freeze
    AI_LATENCY_BUCKETS = [ 0.25, 0.5, 1, 2, 4, 8, 16, 32 ].freeze

    # get-or-register, so code reloading in development does not re-register a metric.
    def self.counter(name, docstring, labels = [])
      REGISTRY.get(name) || REGISTRY.counter(name, docstring: docstring, labels: labels)
    end

    def self.gauge(name, docstring, labels = [])
      REGISTRY.get(name) || REGISTRY.gauge(name, docstring: docstring, labels: labels)
    end

    def self.histogram(name, docstring, labels, buckets)
      REGISTRY.get(name) || REGISTRY.histogram(name, docstring: docstring, labels: labels, buckets: buckets)
    end

    HTTP_REQUESTS = counter(:taskapi_http_requests_total, "HTTP requests handled", %i[controller action status])
    HTTP_DURATION = histogram(:taskapi_http_request_duration_seconds, "HTTP request duration", %i[controller action], LATENCY_BUCKETS)
    DOMAIN_EVENTS = counter(:taskapi_domain_events_total, "Domain events published (task.created, project.updated, ...)", %i[event])

    AI_REQUESTS = counter(:taskapi_ai_requests_total, "Model calls by feature and outcome", %i[feature outcome])
    AI_TOKENS = counter(:taskapi_ai_tokens_total, "Model tokens consumed", %i[feature direction])
    AI_COST = counter(:taskapi_ai_cost_usd_total, "Estimated model spend in USD", %i[feature])
    AI_LATENCY = histogram(:taskapi_ai_request_duration_seconds, "Model call latency", %i[feature], AI_LATENCY_BUCKETS)
    AI_BUDGET_REJECTIONS = counter(:taskapi_ai_budget_rejections_total, "Calls refused because a daily budget was used up")

    QUEUE_READY = gauge(:taskapi_queue_ready_jobs, "Jobs waiting to run", %i[queue])
    QUEUE_OLDEST_AGE = gauge(:taskapi_queue_oldest_ready_job_age_seconds, "Age of the oldest waiting job (queue latency)", %i[queue])
    QUEUE_CLAIMED = gauge(:taskapi_queue_claimed_jobs, "Jobs being worked on right now")
    QUEUE_SCHEDULED = gauge(:taskapi_queue_scheduled_jobs, "Jobs scheduled for later (retries, delays)")
    QUEUE_FAILED = gauge(:taskapi_queue_failed_jobs, "Jobs that exhausted their retries and need attention")
    QUEUE_WORKERS = gauge(:taskapi_queue_workers, "Live Solid Queue worker processes")
    COLLECTOR_ERRORS = counter(:taskapi_collector_errors_total, "Scrape-time collection failures", %i[collector])

    DB_POOL = gauge(:taskapi_db_pool_connections, "Active Record connection pool", %i[state])
    BUILD_INFO = gauge(:taskapi_build_info, "Build metadata (value is always 1)", %i[version ruby rails])
  end
end
