require "spec_helper"
require_relative "../support"

RSpec.describe AiCore::Eval::Runner do
  let(:dataset) do
    [
      { "name" => "right", "input" => { "text" => "Review the PR", "today" => "2026-10-29" }, "expected" => { "title" => "Review the PR", "due_on" => nil } },
      { "name" => "wrong date", "input" => { "text" => "Review the PR", "today" => "2026-10-29" }, "expected" => { "title" => "Review the PR", "due_on" => "2026-11-03" } }
    ]
  end

  it "averages the metrics and lists the examples that were not perfect" do
    report = described_class.new(client: scripted_client("title" => "Review the PR")).run("parse_task", dataset: dataset)

    expect(report.examples).to eq(2)
    expect(report.scores).to eq(title: 1.0, due_on: 0.5)
    expect(report.failures.map { |failure| failure[:name] }).to eq([ "wrong date" ])
    expect(report.usage.total_tokens).to eq(30)
    expect(report.passed?(0.5)).to be(true)
    expect(report.passed?(0.9)).to be(false)
  end

  it "counts provider failures as errors instead of crashing the run" do
    broken = AiCore::Client.new(provider: AiCore::Providers::Fake.new(ai_config, responder: ->(_) { raise AiCore::Unavailable, "throttled" }), config: ai_config)
    report = described_class.new(client: broken).run("parse_task", dataset: dataset)

    expect(report.scores).to eq(errors: 0.0)
    expect(report.failures.first).to include(error: "throttled")
  end

  describe "the offline baseline on the shipped golden sets" do
    let(:runner) { described_class.new(client: AiCore::Client.new(provider: AiCore::Providers::Fake.new(ai_config), config: ai_config)) }

    it "parses dates reliably" do
      expect(runner.run("parse_task").scores.fetch(:due_on)).to be >= 0.9
    end

    it "keeps priorities within one level" do
      expect(runner.run("suggest_priority").scores.fetch(:priority_within_one)).to be >= 0.85
    end

    it "finds most tags" do
      expect(runner.run("suggest_tags").scores.fetch(:tags_f1)).to be >= 0.8
    end
  end
end
