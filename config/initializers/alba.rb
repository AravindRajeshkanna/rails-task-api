# Encode with ActiveSupport::JSON so timestamps are ISO 8601 ("2026-10-29T01:00:37.123Z"),
# matching the rest of Rails, instead of the json gem's Time#to_s.
Alba.backend = :active_support
Alba.inflector = :active_support
