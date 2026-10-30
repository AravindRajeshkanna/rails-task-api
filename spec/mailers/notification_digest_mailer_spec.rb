require "rails_helper"

RSpec.describe NotificationDigestMailer do
  let(:user) { create(:user, name: "Ada", email_address: "ada@example.com") }
  let(:items) do
    [
      { "kind" => "task.assigned", "project_id" => 3, "project_name" => "Apollo", "task_id" => 7, "task_title" => "Land on the moon" },
      { "kind" => "comment.created", "project_id" => 3, "project_name" => "Apollo", "task_id" => 7, "task_title" => "Land on the moon", "comment_excerpt" => "Looks good" },
      { "kind" => "task.due_soon", "project_id" => 4, "project_name" => "Gemini", "task_id" => 9, "task_title" => "Dock" }
    ]
  end

  subject(:mail) { described_class.daily(user, items) }

  it "groups what is new by project, says what happened, and links each task" do
    expect(mail).to have_attributes(to: [ "ada@example.com" ], subject: "Your daily summary: 3 updates")
    body = mail.body.to_s
    expect(body).to include("Hi Ada", "Apollo", "Gemini", "assigned to you: Land on the moon", "new comment: Land on the moon", "(\"Looks good\")", "due tomorrow: Dock")
    expect(body).to include("#{Rails.configuration.x.frontend_url}/projects/3/tasks/7", "#{Rails.configuration.x.frontend_url}/projects/4/tasks/9")
    expect(body.scan("Apollo").size).to eq(1) # a heading, not a repeat per item
  end

  it "says how to change it" do
    expect(mail.body.to_s).to include("#{Rails.configuration.x.frontend_url}/settings/notifications", "instead of an email for each event")
  end

  it "uses the singular for one update" do
    expect(described_class.daily(user, items.first(1)).subject).to eq("Your daily summary: 1 update")
  end

  it "knows a label for every kind of notification" do
    expect(described_class::LABELS.keys).to match_array(Notification::KINDS)
  end
end
