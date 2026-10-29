module AiCore
  module Features
    # "Remind me to review the PR next Tuesday" -> { title: "Review the PR", due_on: "2026-11-03", ... }
    #
    # Input:  { "text", "today" (YYYY-MM-DD), "timezone", "members": [{id, name}], "tags": [names] }
    class ParseTask < Base
      class << self
        def description = "Turn free text into a structured task."

        def instructions
          <<~TEXT
            Convert the user's sentence into one task.
            - title: short, imperative, without the date phrase ("Review the PR"), at most 120 characters.
            - due_on: resolve relative dates ("tomorrow", "next Tuesday", "in 3 days") against today to a
              YYYY-MM-DD date. "Next <weekday>" is the first such weekday after today. Omit it when no date is implied.
            - priority: only when the text implies one (urgent, ASAP, whenever, low priority).
            - assignee_id: only when the text names one of the listed members.
            - tag_names: up to 5, preferring the listed existing tags.
            Leave out anything the text does not state; do not invent details.
          TEXT
        end

        def schema
          {
            type: "object",
            properties: {
              title: { type: "string" },
              description: { type: "string", description: "Extra context from the text; omit if none" },
              due_on: { type: "string", description: "YYYY-MM-DD" },
              priority: { type: "string", enum: PRIORITIES },
              assignee_id: { type: "integer" },
              tag_names: { type: "array", items: { type: "string" } }
            },
            required: [ "title" ]
          }
        end

        def normalize(raw, input)
          title = string(raw["title"], max: 200) or invalid!("missing title")
          today = date(input["today"])
          due_on = date(raw["due_on"])
          due_on = nil if today && due_on && due_on < today
          member_ids = Array(input["members"]).map { |member| member["id"] }
          assignee_id = Integer(raw["assignee_id"], exception: false)

          {
            title: title,
            description: string(raw["description"], max: 2_000),
            due_on: due_on&.iso8601,
            priority: enum(raw["priority"], PRIORITIES),
            assignee_id: (assignee_id if member_ids.include?(assignee_id)),
            tag_names: Array(raw["tag_names"]).filter_map { |name| tag_name(name) }.uniq.first(5)
          }
        end
      end
    end
  end
end
