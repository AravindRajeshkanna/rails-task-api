require "rails_helper"

RSpec.describe Ai::Budget do
  let(:user) { create(:user) }
  let(:project) { create(:project, owner: user) }

  def spend(tokens, **attributes)
    AiUsage.create!({ user: user, project: project, feature: "chat", input_tokens: tokens, output_tokens: 0 }.merge(attributes))
  end

  around do |example|
    original = Ai.config.slice(:daily_tokens_per_user, :daily_tokens_per_project).to_h
    Ai.config.daily_tokens_per_user = 1_000
    Ai.config.daily_tokens_per_project = 5_000
    travel_to(Time.utc(2026, 10, 29, 22, 0)) { example.run }
  ensure
    original.each { |key, value| Ai.config[key] = value }
  end

  it "allows spending under the limits" do
    spend(999)

    expect { described_class.new(user: user, project: project).check! }.not_to raise_error
  end

  it "blocks a user who used up the day, with the time until the UTC reset" do
    spend(1_000)

    expect { described_class.new(user: user).check! }.to raise_error(Ai::BudgetExceeded) { |error|
      expect(error.retry_after).to eq(2.hours.to_i)
    }
  end

  it "blocks everyone in a project that used up its budget" do
    other = create(:user)
    5.times { spend(1_000, user: create(:user)) }

    expect { described_class.new(user: other, project: project).check! }.to raise_error(Ai::BudgetExceeded)
  end

  it "starts fresh each UTC day and ignores failed calls" do
    spend(1_000, created_at: 1.day.ago)
    spend(5_000, outcome: "error")

    expect { described_class.new(user: user, project: project).check! }.not_to raise_error
  end

  it "summarises today's spending for the caller" do
    spend(300, cost_micros: 2_500_000)

    expect(described_class.new(user: user).summary).to include(
      day: "2026-10-29", tokens_used: 300, daily_token_limit: 1_000, tokens_remaining: 700, calls: 1, cost_usd: 2.5, resets_at: "2026-10-30T00:00:00Z"
    )
  end
end
