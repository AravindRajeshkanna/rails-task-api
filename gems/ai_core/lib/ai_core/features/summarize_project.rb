module AiCore
  module Features
    # Input: { "project": {name, description}, "today", "stats": {todo, in_progress, done, overdue},
    #          "completed_recently": [...], "in_progress": [...], "overdue": [...], "unassigned": n }
    class SummarizeProject < Base
      class << self
        def description = "Summarize a project's progress for its team."

        def instructions
          <<~TEXT
            Write a short status report for the project from the numbers and task lists provided.
            Be factual: mention only what the data shows and quote counts exactly. headline is one line.
            summary is two to four sentences. highlights are wins, risks are things that may slip (overdue,
            unassigned or stalled work), next_steps are concrete suggestions. No more than five items each.
          TEXT
        end

        def schema
          {
            type: "object",
            properties: {
              headline: { type: "string" },
              summary: { type: "string" },
              highlights: { type: "array", items: { type: "string" } },
              risks: { type: "array", items: { type: "string" } },
              next_steps: { type: "array", items: { type: "string" } }
            },
            required: %w[headline summary]
          }
        end

        def normalize(raw, _input)
          {
            headline: string(raw["headline"], max: 140) || invalid!("missing headline"),
            summary: string(raw["summary"], max: 1_200) || invalid!("missing summary"),
            highlights: list(raw["highlights"], max_items: 5, max_length: 200),
            risks: list(raw["risks"], max_items: 5, max_length: 200),
            next_steps: list(raw["next_steps"], max_items: 5, max_length: 200)
          }
        end
      end
    end
  end
end
