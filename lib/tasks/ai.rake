namespace :ai do
  desc "Score the configured model against the golden datasets (FEATURE=parse_task|suggest_priority|suggest_tags, MIN=0.8)"
  task eval: :environment do
    features = ENV["FEATURE"] ? [ ENV["FEATURE"] ] : %w[parse_task suggest_priority suggest_tags]
    threshold = Float(ENV.fetch("MIN", 0.7))
    provider = AiCore.configuration.provider
    puts "Provider: #{provider}#{" (#{AiCore.configuration.model_id})" if AiCore.configuration.model_id}  |  pass mark: #{threshold}"
    puts "Note: the fake provider is a rule-based baseline, not a model." if provider == "fake"

    runner = AiCore::Eval::Runner.new
    reports = features.map { |feature| runner.run(feature) }

    reports.each do |report|
      puts "\n#{report.feature}  (#{report.examples} examples, #{report.usage.total_tokens} tokens)"
      report.scores.each { |metric, score| puts format("  %-20s %5.1f%%  %s", metric, score * 100, score >= threshold ? "ok" : "BELOW PASS MARK") }
      report.failures.each do |failure|
        puts "  - #{failure[:name]}: #{failure[:error] || "expected #{failure[:expected].to_json}, got #{failure[:actual].to_json}"}"
      end
    end

    abort "\nEvaluation failed: at least one metric is below #{threshold}." unless reports.all? { |report| report.passed?(threshold) }
    puts "\nAll metrics at or above #{threshold}."
  end

  desc "Embed tasks that have no embedding yet (run after enabling AI, or after changing the embedding model)"
  task backfill_embeddings: :environment do
    abort "AI is not configured" unless Ai.enabled?

    scope = Task.kept.where(embedding: nil)
    scope = Task.kept if ENV["ALL"] == "true"
    puts "Queueing #{scope.count} tasks..."
    scope.find_each { |task| EmbedTaskJob.perform_later(task) }
  end

  desc "Today's AI spend per feature"
  task usage: :environment do
    rows = AiUsage.since(Time.current.utc.beginning_of_day).group(:feature, :outcome)
      .pluck(:feature, :outcome, Arel.sql("COUNT(*)"), Arel.sql("SUM(input_tokens + output_tokens)"), Arel.sql("SUM(cost_micros)"))
    puts format("%-20s %-8s %6s %12s %10s", "feature", "outcome", "calls", "tokens", "usd")
    rows.each { |feature, outcome, calls, tokens, micros| puts format("%-20s %-8s %6d %12d %10.4f", feature, outcome, calls, tokens, micros / 1_000_000.0) }
  end
end
