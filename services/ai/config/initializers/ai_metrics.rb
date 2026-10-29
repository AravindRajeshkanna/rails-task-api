# Model-call metrics for /metrics, fed by the "ai.completed" events AiService::Inference emits.
module AiServiceMetrics
  REQUESTS = ServiceKit::Metrics.counter(:ai_service_requests_total, "Model calls by feature and outcome", %i[feature outcome])
  TOKENS = ServiceKit::Metrics.counter(:ai_service_tokens_total, "Model tokens consumed", %i[feature direction])
  LATENCY = ServiceKit::Metrics.histogram(:ai_service_model_duration_seconds, "Model call latency", %i[feature], [ 0.25, 0.5, 1, 2, 4, 8, 16, 32 ])

  class Subscriber
    def emit(event)
      return unless event[:name] == "ai.completed"

      payload = event[:payload]
      feature = payload[:feature].to_s
      REQUESTS.increment(labels: { feature: feature, outcome: payload[:outcome].to_s })
      return unless payload[:outcome] == "ok"

      TOKENS.increment(by: payload[:input_tokens].to_i, labels: { feature: feature, direction: "input" })
      TOKENS.increment(by: payload[:output_tokens].to_i, labels: { feature: feature, direction: "output" })
      LATENCY.observe(payload[:latency_ms].to_f / 1000, labels: { feature: feature })
    end
  end
end

Rails.application.config.after_initialize { Rails.event.subscribe(AiServiceMetrics::Subscriber.new) }
