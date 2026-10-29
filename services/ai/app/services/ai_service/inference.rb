module AiService
  # Runs a model call and reports it: one "ai.completed" event per call (success or failure), which
  # feeds the logs and /metrics. Never logs prompts or completions, only sizes and timing.
  module Inference
    module_function

    def call(feature)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      usage = result.usage
      Rails.event.notify("ai.completed", feature: feature, outcome: "ok", model_id: usage.model_id,
        input_tokens: usage.input_tokens.to_i, output_tokens: usage.output_tokens.to_i, latency_ms: usage.latency_ms.to_i)
      result
    rescue AiCore::Error => error
      elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      Rails.event.notify("ai.completed", feature: feature, outcome: "error", error: error.class.name.demodulize, latency_ms: elapsed,
        input_tokens: 0, output_tokens: 0)
      raise
    end
  end
end
