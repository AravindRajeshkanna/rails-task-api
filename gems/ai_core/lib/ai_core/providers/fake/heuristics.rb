require "zlib"

module AiCore
  module Providers
    class Fake
      # Deterministic, rule-based answers for every feature. Good enough to exercise the whole
      # API offline, and a useful baseline: `rake ai:eval` can score it next to a real model.
      module Heuristics
        WEEKDAYS = %w[sunday monday tuesday wednesday thursday friday saturday].freeze
        KEYWORD_TAGS = {
          "bug" => %w[bug fix broken crash error regression],
          "docs" => %w[docs documentation readme guide],
          "design" => %w[design mockup wireframe ui ux],
          "testing" => %w[test tests qa spec specs],
          "devops" => %w[deploy ci cd pipeline docker infra],
          "frontend" => %w[frontend css react button form page],
          "backend" => %w[backend api database migration endpoint]
        }.freeze
        LEAD_INS = /\A(please\s+)?(remind me to|remember to|i need to|i have to|i should|todo:?|don't forget to)\s+/i

        module_function

        def answer(feature, input)
          case feature
          when "parse_task" then parse_task(input)
          when "suggest_priority" then suggest_priority(input)
          when "suggest_tags" then suggest_tags(input)
          when "summarize_project" then summarize_project(input)
          when "analyze_incident" then analyze_incident(input)
          else {}
          end
        end

        def parse_task(input)
          text = input["text"].to_s
          today = Date.iso8601(input["today"])
          due_on, phrase = due_date(text, today)
          title = text.sub(LEAD_INS, "")
          title = title.sub(/\s*#{Regexp.escape(phrase)}\s*/i, " ") if phrase
          title = title.sub(/\s+(by|on|before|due)\s*\z/i, "").strip
          title = title.sub(/\A./) { |char| char.upcase }

          member = Array(input["members"]).find { |candidate| text.match?(/\b#{Regexp.escape(candidate['name'].to_s.split.first.to_s)}\b/i) }
          tags = Array(input["tags"]).select { |tag| text.match?(/\b#{Regexp.escape(tag)}\b/i) }

          { "title" => title, "due_on" => due_on&.iso8601, "priority" => priority_from(text), "assignee_id" => member&.fetch("id"), "tag_names" => tags }.compact
        end

        def suggest_priority(input)
          task = input["task"] || {}
          text = "#{task['title']} #{task['description']}"
          today = Date.iso8601(input["today"])
          due = (Date.iso8601(task["due_on"]) if task["due_on"])
          signals = input["signals"] || {}

          priority = priority_from(text)
          priority ||= if due && (due - today) <= 1 then "urgent"
          elsif due && (due - today) <= 3 then "high"
          elsif due.nil? && text.match?(/\b(someday|maybe|nice to have)\b/i) then "low"
          else "medium"
          end

          days = signals["baseline_days"] || { "urgent" => 1, "high" => 3, "medium" => 7, "low" => 14 }.fetch(priority)
          reasons = []
          reasons << "keywords in the text" if priority_from(text)
          reasons << "due in #{(due - today).to_i} day(s)" if due
          reasons << "similar tasks took about #{signals['baseline_days']} day(s)" if signals["baseline_days"]

          { "priority" => priority, "rationale" => "Heuristic baseline: #{(reasons.empty? ? 'no strong signals' : reasons.join(', '))}.", "estimated_days" => days, "confidence" => 0.4 }
        end

        def suggest_tags(input)
          task = input["task"] || {}
          words = "#{task['title']} #{task['description']}".downcase.scan(/[a-z]+/)
          existing = Array(input["existing_tags"])

          names = existing.select { |tag| words.any? { |word| word_matches?(word, tag.downcase) } }
          names |= KEYWORD_TAGS.filter_map { |tag, keywords| tag if keywords.any? { |keyword| words.any? { |word| word_matches?(word, keyword) } } }
          { "tags" => names.first(5).map { |name| { "name" => name, "confidence" => 0.6 } } }
        end

        def summarize_project(input)
          stats = input["stats"] || {}
          total = stats.values_at("todo", "in_progress", "done").sum(&:to_i)
          done = stats["done"].to_i
          overdue = stats["overdue"].to_i

          {
            "headline" => "#{input.dig('project', 'name')}: #{done} of #{total} tasks done",
            "summary" => "#{stats['todo'].to_i} to do, #{stats['in_progress'].to_i} in progress and #{done} done. #{overdue} overdue.",
            "highlights" => Array(input["completed_recently"]).first(3).map { |task| "Completed: #{task['title']}" },
            "risks" => (overdue.positive? ? [ "#{overdue} task(s) are overdue" ] : []) + (input["unassigned"].to_i.positive? ? [ "#{input['unassigned']} open task(s) have no assignee" ] : []),
            "next_steps" => Array(input["overdue"]).first(3).map { |task| "Unblock: #{task['title']}" }
          }
        end

        def analyze_incident(input)
          deploy = input.dig("evidence", "recent_deploys")
          {
            "summary" => "#{input.dig('alarm', 'name')} is firing.",
            "likely_cause" => deploy.to_s.empty? ? "Heuristic baseline: not enough evidence to name a cause." : "Heuristic baseline: a deploy happened shortly before the alarm (#{deploy.to_s[0, 120]}).",
            "confidence" => "low",
            "suggested_actions" => [ "Open the Task API dashboard", "Compare with the previous deploy" ]
          }
        end

        # A canned chatbot: enough to demo the tool loop without a model.
        def chat_turn(messages)
          last = messages.last.fetch(:content)
          if (result = last.filter_map { |block| block[:tool_result] }.first)
            [ { text: "Done. Here is what I found: #{truncate(result[:content].filter_map { |block| block[:text] }.join)}" } ]
          else
            text = last.filter_map { |block| block[:text] }.join
            if (title = text[/\b(?:create|add)(?: a)? task:?\s+(.+)/i, 1])
              [ { tool_use: { tool_use_id: "fake-chat-1", name: "create_task", input: { "title" => title.strip } } } ]
            elsif text.match?(/\b(overdue|my tasks|list|show)\b/i)
              [ { tool_use: { tool_use_id: "fake-chat-1", name: "list_tasks", input: text.match?(/overdue/i) ? { "overdue" => true } : {} } } ]
            else
              [ { text: "I'm the offline demo assistant. Try \"list my tasks\", \"show overdue tasks\" or \"create task: write docs\"." } ]
            end
          end
        end

        # Hashed bag-of-words, L2-normalised: texts sharing words are close in cosine distance.
        def embedding(text, dimensions)
          vector = Array.new(dimensions, 0.0)
          text.downcase.scan(/[a-z0-9]+/).each { |word| vector[Zlib.crc32(word) % dimensions] += 1.0 }
          vector[0] = 1.0 if vector.all?(&:zero?)
          norm = Math.sqrt(vector.sum { |value| value * value })
          vector.map { |value| (value / norm).round(6) }
        end

        # "specs" matches spec, "redesign" matches design; short keywords must match whole words.
        def word_matches?(word, keyword)
          word == keyword || word == "#{keyword}s" || (keyword.length > 4 && word.end_with?(keyword))
        end

        def truncate(text, max = 300) = text.length > max ? "#{text[0, max - 1]}…" : text

        def priority_from(text)
          case text
          when /\b(urgent|asap|immediately|critical|outage|p0)\b/i then "urgent"
          when /\b(important|high priority|blocker|blocking)\b/i then "high"
          when /\b(low priority|whenever|someday|nice to have)\b/i then "low"
          end
        end

        # Returns [date, matched phrase] or nil.
        def due_date(text, today)
          if (match = text.match(/\b(\d{4}-\d{2}-\d{2})\b/))
            [ Date.iso8601(match[1]), match[0] ]
          elsif (match = text.match(/\bday after tomorrow\b/i))
            [ today + 2, match[0] ]
          elsif (match = text.match(/\btomorrow\b/i))
            [ today + 1, match[0] ]
          elsif (match = text.match(/\b(today|tonight)\b/i))
            [ today, match[0] ]
          elsif (match = text.match(/\bin (\d+) (day|week)s?\b/i))
            [ today + match[1].to_i * (match[2].casecmp?("week") ? 7 : 1), match[0] ]
          elsif (match = text.match(/\bnext week\b/i))
            [ today + 7, match[0] ]
          elsif (match = text.match(/\b(?:(next|this|on)\s+)?(#{WEEKDAYS.join('|')})\b/i))
            target = WEEKDAYS.index(match[2].downcase)
            ahead = (target - today.wday) % 7
            ahead = 7 if ahead.zero?
            [ today + ahead, match[0] ]
          end
        end
      end
    end
  end
end
