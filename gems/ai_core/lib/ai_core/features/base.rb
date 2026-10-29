module AiCore
  module Features
    PRIORITIES = %w[low medium high urgent].freeze

    # A feature is a forced tool call: a JSON schema the model must fill in, plus a strict
    # normalizer that never trusts the answer (enums, dates, ids and lengths are re-checked).
    # Features are pure: input hash in, validated hash out. Anything that needs the database
    # (members, tags, similar tasks) is supplied by the caller inside +input+.
    class Base
      class << self
        def feature_name = name.split("::").last.gsub(/([a-z])([A-Z])/, '\1_\2').downcase

        def tool = { name: feature_name, description: description, input_schema: schema }

        def description = raise(NotImplementedError)
        def schema = raise(NotImplementedError)
        def instructions = raise(NotImplementedError)

        def system_prompt = "#{Prompting::PREAMBLE}\n#{instructions}"

        def user_prompt(input) = "#{header(input)}\n#{Prompting.input_block(input)}"

        # +raw+ is the model's tool input (string keys); returns a symbol-keyed hash or raises InvalidResponse.
        def normalize(_raw, _input) = raise(NotImplementedError)

        private
          def header(input) = "Today is #{input['today']}."

          def invalid!(message) = raise(InvalidResponse, "#{feature_name}: #{message}")

          def string(value, max:)
            value = value.to_s.gsub(/\s+/, " ").strip
            value.empty? ? nil : value[0, max]
          end

          def enum(value, allowed)
            value = value.to_s.strip.downcase
            value if allowed.include?(value)
          end

          def date(value)
            Date.iso8601(value.to_s)
          rescue Date::Error
            nil
          end

          def clamp_integer(value, range)
            Integer(value).clamp(range)
          rescue ArgumentError, TypeError
            nil
          end

          def clamp_float(value, range, default:)
            Float(value).clamp(range.begin, range.end)
          rescue ArgumentError, TypeError
            default
          end

          def list(value, max_items:, max_length:)
            Array(value).filter_map { |item| string(item, max: max_length) }.first(max_items)
          end

          def tag_name(value) = string(value.to_s.downcase, max: 30)
      end
    end
  end
end
