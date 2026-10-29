require "rails_helper"

RSpec.describe Analytics::ProjectReport do
  let(:project) { create(:project) }
  let(:ada) { create(:user, name: "Ada") }
  let(:today) { Time.utc(2026, 10, 29, 12) } # a Thursday

  around { |example| travel_to(today) { example.run } }

  before { create(:membership, project: project, user: ada) }

  # Backdates the columns the model manages itself (and update_columns skips callbacks, so no events fire).
  def task(created:, completed: nil, **attributes)
    create(:task, project: project, **attributes).tap do |task|
      task.update_columns(created_at: Time.utc(*created), completed_at: completed && Time.utc(*completed))
    end
  end

  def report(**form_attributes)
    described_class.new(project, Analytics::ReportForm.new({ from: "2026-10-12", to: "2026-10-29" }.merge(form_attributes))).call
  end

  before do
    task(created: [ 2026, 10, 13 ], completed: [ 2026, 10, 14 ], status: :done)                       # took 24 hours
    task(created: [ 2026, 10, 20, 10 ], completed: [ 2026, 10, 22, 10 ], status: :done)               # took 48 hours
    task(created: [ 2026, 10, 21 ], assignee: ada, priority: :urgent, due_on: Date.new(2026, 10, 25)) # overdue
    task(created: [ 2026, 10, 27 ], assignee: ada, status: :in_progress, priority: :low, due_on: Date.new(2026, 11, 5))
    task(created: [ 2026, 9, 1 ], priority: :high)                                                    # before the window, unassigned
    task(created: [ 2026, 10, 15 ], discarded_at: Time.utc(2026, 10, 16))                             # deleted: counts nowhere
  end

  it "counts live tasks by status and, for open work, by priority" do
    expect(report).to include(
      by_status: { "todo" => 2, "in_progress" => 1, "done" => 2 },
      by_priority: { "low" => 1, "medium" => 0, "high" => 1, "urgent" => 1 }
    )
  end

  it "summarises what is open, overdue and unowned" do
    expect(report[:totals]).to eq(total: 5, open: 3, done: 2, overdue: 1, unassigned: 1)
  end

  it "reports created and completed per week, with every week present" do
    expect(report[:throughput]).to eq([
      { period: Date.new(2026, 10, 12), created: 1, completed: 1 },
      { period: Date.new(2026, 10, 19), created: 2, completed: 1 },
      { period: Date.new(2026, 10, 26), created: 1, completed: 0 }
    ])
  end

  it "can bucket by day or month instead" do
    daily = report(from: "2026-10-26", to: "2026-10-29", interval: "day")[:throughput]
    expect(daily.map { |row| row[:period] }).to eq((Date.new(2026, 10, 26)..Date.new(2026, 10, 29)).to_a)
    expect(daily.sum { |row| row[:created] }).to eq(1)

    monthly = report(from: "2026-09-01", to: "2026-10-29", interval: "month")[:throughput]
    expect(monthly).to eq([
      { period: Date.new(2026, 9, 1), created: 1, completed: 0 },
      { period: Date.new(2026, 10, 1), created: 4, completed: 2 }
    ])
  end

  it "measures how long tasks completed in the window took" do
    expect(report[:cycle_time_hours]).to eq(sample: 2, median: 36.0, p90: 45.6)
  end

  it "has no cycle time, rather than a made-up one, when nothing was completed" do
    expect(report(from: "2026-10-23", to: "2026-10-29")[:cycle_time_hours]).to eq(sample: 0, median: nil, p90: nil)
  end

  it "shows who is carrying what, without exposing email addresses" do
    expect(report[:workload]).to eq([ { assignee: { id: ada.id, name: "Ada" }, open: 2, overdue: 1 } ])
  end

  it "does not look at other projects" do
    create(:task, project: create(:project), status: :done)

    expect(report[:totals][:total]).to eq(5)
  end

  it "runs a fixed number of queries however many people and tasks there are" do
    create_list(:user, 5).each { |user| create(:membership, project: project, user: user) && task(created: [ 2026, 10, 28 ], assignee: user) }

    expect(count_queries { report }).to be <= 12
  end
end
