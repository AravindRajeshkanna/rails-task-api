module AiCore
  module Features
    # Priority plus a completion estimate, grounded in what happened to similar past tasks.
    #
    # Input: { "task": {title, description, due_on, status}, "today",
    #          "signals": { "similar": [{title, priority, days_to_complete}], "baseline_days",
    #                       "assignee_open_tasks", "project_open_tasks" } }
    class SuggestPriority < Base
      class << self
        def description = "Recommend a priority and estimate how many days the task will take."

        def instructions
          <<~TEXT
            Pick a priority for the task:
            - urgent: blocks others, an outage or security issue, or due within a day.
            - high: due within about three days, or clear user or business impact.
            - medium: the default for normal planned work.
            - low: nice-to-have with no deadline.
            Use the similar past tasks and baseline_days (median days they took) to set estimated_days,
            the calendar days from today until this task is likely done. Explain the choice in one or two
            sentences in rationale, citing the signals you used.
          TEXT
        end

        def schema
          {
            type: "object",
            properties: {
              priority: { type: "string", enum: PRIORITIES },
              rationale: { type: "string" },
              estimated_days: { type: "integer", description: "Calendar days until done, 0 to 365" },
              confidence: { type: "number", description: "0 to 1" }
            },
            required: %w[priority rationale]
          }
        end

        def normalize(raw, _input)
          priority = enum(raw["priority"], PRIORITIES) or invalid!("unknown priority #{raw['priority'].inspect}")

          {
            priority: priority,
            rationale: string(raw["rationale"], max: 500) || "No rationale given.",
            estimated_days: clamp_integer(raw["estimated_days"], 0..365),
            confidence: clamp_float(raw["confidence"], 0.0..1.0, default: 0.5).round(2)
          }
        end
      end
    end
  end
end
