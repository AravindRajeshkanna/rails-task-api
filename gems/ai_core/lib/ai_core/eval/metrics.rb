module AiCore
  module Eval
    # Scoring rules, one per feature. Each takes (expected, actual) hashes and returns
    # { name => score between 0.0 and 1.0 } for the example.
    module Metrics
      PRIORITY_ORDER = %w[low medium high urgent].freeze

      module_function

      def score(feature, expected, actual)
        case feature
        when "parse_task" then parse_task(expected, actual)
        when "suggest_priority" then suggest_priority(expected, actual)
        when "suggest_tags" then suggest_tags(expected, actual)
        else raise ArgumentError, "No metrics for #{feature}"
        end
      end

      def parse_task(expected, actual)
        scores = {
          title: normalize(expected["title"]) == normalize(actual[:title]) ? 1.0 : token_overlap(expected["title"], actual[:title]),
          due_on: expected["due_on"] == actual[:due_on] ? 1.0 : 0.0
        }
        scores[:priority] = expected["priority"] == actual[:priority] ? 1.0 : 0.0 if expected.key?("priority")
        scores[:assignee_id] = expected["assignee_id"] == actual[:assignee_id] ? 1.0 : 0.0 if expected.key?("assignee_id")
        scores[:tags] = f1(Array(expected["tag_names"]), Array(actual[:tag_names])) if expected.key?("tag_names")
        scores
      end

      def suggest_priority(expected, actual)
        distance = (PRIORITY_ORDER.index(expected["priority"]) - PRIORITY_ORDER.index(actual[:priority])).abs
        { priority_exact: distance.zero? ? 1.0 : 0.0, priority_within_one: distance <= 1 ? 1.0 : 0.0 }
      end

      def suggest_tags(expected, actual)
        { tags_f1: f1(Array(expected["tags"]), actual.map { |tag| tag[:name] }) }
      end

      def f1(expected, actual)
        expected = expected.map(&:to_s).uniq
        actual = actual.map(&:to_s).uniq
        return 1.0 if expected.empty? && actual.empty?

        hits = (expected & actual).size
        return 0.0 if hits.zero?

        precision = hits.fdiv(actual.size)
        recall = hits.fdiv(expected.size)
        2 * precision * recall / (precision + recall)
      end

      def token_overlap(expected, actual) = f1(normalize(expected).split, normalize(actual).split)

      def normalize(text) = text.to_s.downcase.gsub(/[^a-z0-9 ]/, " ").squeeze(" ").strip
    end
  end
end
