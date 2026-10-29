require "rails_helper"

RSpec.describe DueSoonRemindersJob do
  let(:project) { create(:project) }
  let(:assignee) { create(:membership, project:).user }

  it "emails assignees of unfinished tasks due tomorrow" do
    due = create(:task, project:, assignee:, due_on: Date.tomorrow)

    expect { described_class.perform_now }.to have_enqueued_mail(TaskMailer, :due_soon).with(due).once
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
