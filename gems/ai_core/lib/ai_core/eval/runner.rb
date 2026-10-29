require "yaml"
require_relative "metrics"

module AiCore
  module Eval
    # Replays a golden dataset through a client and averages the metric scores.
    #
    # Dataset (evals/<feature>.yml):
    #   - name: "relative weekday"
    #     input: { text: "...", today: "2026-10-29", ... }
    #     expected: { title: "...", due_on: "2026-11-03" }
    class Runner
      Report = Struct.new(:feature, :examples, :scores, :failures, :usage, keyword_init: true) do
        def mean = scores.values.sum / scores.size
        def passed?(threshold) = scores.values.all? { |score| score >= threshold }
      end

      def self.dataset_path(feature) = File.expand_path("../../../evals/#{feature}.yml", __dir__)

      def initialize(client: AiCore.client)
        @client = client
      end

      def run(feature, dataset: YAML.safe_load_file(self.class.dataset_path(feature)))
        totals = Hash.new { |hash, key| hash[key] = [] }
        failures = []
        usage = Usage.zero

        dataset.each do |example|
          result = @client.run(feature, example.fetch("input"))
          usage += result.usage
          Metrics.score(feature, example.fetch("expected"), result.output).each { |metric, value| totals[metric] << value }
          failures << { name: example["name"], expected: example["expected"], actual: result.output } if Metrics.score(feature, example["expected"], result.output).values.any? { |value| value < 1.0 }
        rescue AiCore::Error => error
          totals[:errors] << 0.0
          failures << { name: example["name"], error: error.message }
        end

        Report.new(
          feature: feature, examples: dataset.size, usage: usage, failures: failures,
          scores: totals.transform_values { |values| (values.sum / values.size).round(3) }
        )
      end
    end
  end
end
