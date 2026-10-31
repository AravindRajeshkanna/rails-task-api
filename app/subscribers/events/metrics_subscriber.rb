module Events
  # Turns Rails.event notifications into Prometheus metrics (see Observability::Metrics): request
  # rate/latency/errors from Rails' own action_controller.request_completed, plus our domain and AI events.
  class MetricsSubscriber < Subscriber
    DOMAIN_EVENT = /\A(task|project|comment)\.\w+\z/

    private
      def handle(event)
        payload = event[:payload]
        case event[:name]
        when "action_controller.request_completed" then request_completed(payload)
        when "ai.completed" then ai_completed(payload)
        when "ai.budget_exceeded" then Observability::Metrics::AI_BUDGET_REJECTIONS.increment
        when /\Aidempotency\.(stored|replayed|refused)\z/ then Observability::Metrics::IDEMPOTENCY.increment(labels: { outcome: Regexp.last_match(1), source: payload[:source].to_s })
        when /\Akms\.(request|failed)\z/ then kms_request(payload)
        when "load_shed.rejected" then Observability::Metrics::LOAD_SHED.increment
        when "organization_budget.exceeded" then Observability::Metrics::ORGANIZATION_BUDGET_EXCEEDED.increment
        when "read_only.refused" then Observability::Metrics::READ_ONLY_REFUSALS.increment(labels: { source: payload[:source].to_s })
        when DOMAIN_EVENT then Observability::Metrics::DOMAIN_EVENTS.increment(labels: { event: event[:name] })
        end
      end

      def request_completed(payload)
        route = { controller: payload[:controller].to_s, action: payload[:action].to_s }
        Observability::Metrics::HTTP_REQUESTS.increment(labels: route.merge(status: payload[:status].to_s))
        Observability::Metrics::HTTP_DURATION.observe(payload[:duration_ms].to_f / 1000, labels: route)
      end

      def kms_request(payload)
        operation = payload[:operation].to_s
        Observability::Metrics::KMS_REQUESTS.increment(labels: { operation: operation, outcome: payload[:outcome].to_s })
        Observability::Metrics::KMS_DURATION.observe(payload[:duration_ms].to_f / 1000, labels: { operation: operation })
      end

      def ai_completed(payload)
        feature = payload[:feature].to_s
        Observability::Metrics::AI_REQUESTS.increment(labels: { feature: feature, outcome: payload[:outcome].to_s })
        return unless payload[:outcome] == "ok"

        Observability::Metrics::AI_TOKENS.increment(by: payload[:input_tokens].to_i, labels: { feature: feature, direction: "input" })
        Observability::Metrics::AI_TOKENS.increment(by: payload[:output_tokens].to_i, labels: { feature: feature, direction: "output" })
        Observability::Metrics::AI_COST.increment(by: payload[:cost_micros].to_i / 1_000_000.0, labels: { feature: feature })
        Observability::Metrics::AI_LATENCY.observe(payload[:latency_ms].to_f / 1000, labels: { feature: feature })
      end
  end
end
