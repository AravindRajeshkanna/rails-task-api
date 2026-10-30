require "rails_helper"

RSpec.describe DueSoonRemindersJob do
  let(:project) { create(:project) }
  let(:assignee) { create(:membership, project:).user }

  it "emails assignees of unfinished tasks due tomorrow" do
    due = create(:task, project:, assignee:, due_on: Date.tomorrow)

    expect { described_class.perform_now }.to have_enqueued_mail(TaskMailer, :due_soon).with(due).once
  end

  it "sends no email to someone who muted it or takes a digest, in one lookup for the whole batch" do
    muted = create(:membership, project:).user
    digest = create(:membership, project:).user
    create(:notification_mute, user: muted, kind: "task.due_soon")
    create(:notification_setting, :daily, user: digest)
    create(:task, project:, assignee: muted, due_on: Date.tomorrow)
    create(:task, project:, assignee: digest, due_on: Date.tomorrow)
    kept = create(:task, project:, assignee:, due_on: Date.tomorrow)

    described_class.perform_now

    reminders = enqueued_jobs.select { |job| job["arguments"].first(2) == %w[TaskMailer due_soon] }
    expect(reminders.size).to eq(1) # kept's; not one per task
    expect(reminders.sole["arguments"].last["params"] || reminders.sole["arguments"].to_s).to include(kept.to_global_id.to_s)
  end

  it "skips everything else" do
    create(:task, project:, assignee:, due_on: Date.current)                    # due today
    create(:task, project:, assignee:, due_on: Date.tomorrow + 1)               # due later
    create(:task, :done, project:, assignee:, due_on: Date.tomorrow)            # finished
    create(:task, project:, due_on: Date.tomorrow)                              # nobody to remind
    create(:task, :discarded, project:, assignee:, due_on: Date.tomorrow)       # deleted
    trashed = create(:project, discarded_at: 1.day.ago)
    create(:task, project: trashed, due_on: Date.tomorrow, assignee: create(:membership, project: trashed).user)

    expect { described_class.perform_now }.not_to have_enqueued_mail(TaskMailer, :due_soon)
  end
end
