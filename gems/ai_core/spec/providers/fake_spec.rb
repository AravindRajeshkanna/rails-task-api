require "spec_helper"
require_relative "../support"

RSpec.describe AiCore::Providers::Fake do
  let(:client) { AiCore::Client.new(provider: described_class.new(ai_config), config: ai_config) }
  let(:today) { "2026-10-29" } # a Thursday

  def parse(text, **extra) = client.run("parse_task", { text: text, today: today, **extra }).output

  {
    "Remind me to review the PR next Tuesday" => [ "Review the PR", "2026-11-03" ],
    "Call the vendor today" => [ "Call the vendor", "2026-10-29" ],
    "Email Sam tomorrow" => [ "Email Sam", "2026-10-30" ],
    "Ship the release in 2 weeks" => [ "Ship the release", "2026-11-12" ],
    "Prepare the demo next Thursday" => [ "Prepare the demo", "2026-11-05" ],
    "File taxes by 2026-12-15" => [ "File taxes", "2026-12-15" ]
  }.each do |text, (title, due_on)|
    it "parses #{text.inspect}" do
      expect(parse(text)).to include(title: title, due_on: due_on)
    end
  end

  it "recognises assignees and priority words" do
    result = parse("Ask Taylor to fix the outage asap", members: [ { id: 7, name: "Taylor Teammate" } ])

    expect(result).to include(assignee_id: 7, priority: "urgent")
  end

  it "suggests a priority from the due date and baseline" do
    result = client.run("suggest_priority", { task: { title: "Prepare report", due_on: "2026-10-30" }, today: today, signals: { baseline_days: 4 } }).output

    expect(result).to include(priority: "urgent", estimated_days: 4)
  end

  it "embeds similar texts closer together than unrelated ones" do
    a, b, c = [ "fix login bug", "login bug fix", "buy office plants" ].map { |text| client.embed(text).vector }
    cosine = ->(x, y) { x.zip(y).sum { |p, q| p * q } }

    expect(a.length).to eq(32)
    expect(cosine.call(a, b)).to be > cosine.call(a, c)
  end

  it "plays the chatbot: tool calls first, then a summary of the result" do
    first = client.converse(system: "s", messages: [ { role: "user", content: [ { text: "show overdue tasks" } ] } ], tools: [])
    expect(first.tool_uses.first).to include(name: "list_tasks", input: { "overdue" => true })

    result_turn = { role: "user", content: [ { tool_result: { tool_use_id: "x", content: [ { text: "[]" } ] } } ] }
    expect(client.converse(system: "s", messages: [ result_turn ], tools: []).text).to start_with("Done.")
  end
end
