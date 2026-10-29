require "rails_helper"

RSpec.describe Ai::Runner do
  let(:user) { create(:user) }
  let(:project) { create(:project, owner: user) }
  let(:runner) { described_class.new(user: user, project: project) }
  let(:input) { { text: "Review the PR tomorrow", today: "2026-10-29" } }

  it "records usage and cost for a successful call, and emits an event" do
    AiCore.configuration.price_input_per_mtok = 3.0
    AiCore.configuration.price_output_per_mtok = 15.0

    events = record_events do
      with_ai_responder(->(_) { tool_answer("parse_task", { "title" => "Review the PR" }, tokens: [ 1_000, 100 ]) }) { runner.run("parse_task", input) }
    end

    expect(AiUsage.sole).to have_attributes(
      user: user, project: project, feature: "parse_task", outcome: "ok", model_id: "test-model",
      input_tokens: 1_000, output_tokens: 100, cost_micros: 4_500, latency_ms: 25
    )
    expect(events.payloads("ai.completed").sole).to include(feature: "parse_task", outcome: "ok", input_tokens: 1_000, user_id: user.id)
  ensure
    AiCore.configuration.price_input_per_mtok = 0.0
    AiCore.configuration.price_output_per_mtok = 0.0
  end

  it "records a failed call with zero tokens and re-raises" do
    with_ai_responder(->(_) { raise AiCore::Unavailable, "throttled" }) do
      expect { runner.run("parse_task", input) }.to raise_error(Ai::Unavailable, "throttled")
    end

    expect(AiUsage.sole).to have_attributes(feature: "parse_task", outcome: "error", input_tokens: 0)
  end

  it "maps invalid model output" do
    with_ai_responder(->(_) { text_answer("no json here") }) do
      expect { runner.run("parse_task", input) }.to raise_error(Ai::InvalidResponse)
    end
  end

  it "refuses before calling the model when the budget is gone" do
    AiUsage.create!(user: user, feature: "chat", input_tokens: Ai.config.daily_tokens_per_user)

    with_ai_responder(->(_) { raise "the model must not be called" }) do
      expect { runner.run("parse_task", input) }.to raise_error(Ai::BudgetExceeded)
    end
    expect(AiUsage.where(outcome: "error")).to be_empty
  end

  it "does not log noise when AI is disabled" do
    gateway = instance_double(Ai::Gateway::Local, enabled?: false)

    expect { described_class.new(user: user, gateway: gateway).run("parse_task", input) }.to raise_error(Ai::Disabled)
    expect(AiUsage.count).to eq(0)
  end
end

RSpec.describe "Event payload filtering" do
  it "keeps LLM token counts readable but still hides real tokens" do
    events = record_events { Rails.event.notify("probe", input_tokens: 5, output_tokens: 7, session_token: "secret", api_token: "secret") }

    expect(events.payloads("probe").sole).to eq(input_tokens: 5, output_tokens: 7, session_token: "[FILTERED]", api_token: "[FILTERED]")
  end
end
