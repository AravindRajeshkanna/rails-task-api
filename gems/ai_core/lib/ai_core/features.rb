require_relative "features/base"
require_relative "features/parse_task"
require_relative "features/suggest_priority"
require_relative "features/suggest_tags"
require_relative "features/summarize_project"
require_relative "features/analyze_incident"

module AiCore
  module Features
    ALL = [ ParseTask, SuggestPriority, SuggestTags, SummarizeProject, AnalyzeIncident ].to_h { |feature| [ feature.feature_name, feature ] }.freeze

    def self.fetch(name)
      ALL.fetch(name.to_s) { raise ArgumentError, "Unknown AI feature #{name.inspect}" }
    end
  end
end
