module AiCore
  module Features
    # Input: { "task": {title, description}, "existing_tags": [names], "allow_new": bool, "today" }
    class SuggestTags < Base
      class << self
        def description = "Choose tags for a task."

        def instructions
          <<~TEXT
            Choose up to five short, lowercase tags that categorize the task (for example bug, docs, design,
            devops, frontend). Prefer tags from existing_tags. Only invent a new tag when allow_new is true and
            no existing tag fits. Give each a confidence between 0 and 1; skip weak matches.
          TEXT
        end

        def schema
          {
            type: "object",
            properties: {
              tags: {
                type: "array",
                items: {
                  type: "object",
                  properties: { name: { type: "string" }, confidence: { type: "number" } },
                  required: [ "name" ]
                }
              }
            },
            required: [ "tags" ]
          }
        end

        def normalize(raw, input)
          existing = Array(input["existing_tags"]).map { |name| name.to_s.downcase }
          allow_new = input["allow_new"] != false

          tags = Array(raw["tags"]).filter_map { |entry|
            name = tag_name(entry.is_a?(Hash) ? entry["name"] : entry) or next
            known = existing.include?(name)
            next unless known || allow_new

            { name: name, confidence: clamp_float(entry.is_a?(Hash) ? entry["confidence"] : nil, 0.0..1.0, default: 0.5).round(2), new: !known }
          }

          tags.uniq { |tag| tag[:name] }.sort_by { |tag| -tag[:confidence] }.first(5)
        end
      end
    end
  end
end
