module EventHelpers
  def assigned_event(id: SecureRandom.uuid, email: "bob@example.com", title: "Review the PR")
    cloud_event("task.assigned", id: id, data: {
      "task" => { "id" => 7, "title" => title, "due_on" => "2026-11-03" },
      "project" => { "id" => 3, "name" => "Website" },
      "recipient" => { "id" => 2, "name" => "Bob Builder", "email_address" => email },
      "actor" => { "id" => 1, "name" => "Alice Admin" },
      "url" => "https://app.example.com/projects/3/tasks/7"
    })
  end

  def cloud_event(type, data:, id: SecureRandom.uuid, **extra)
    { "specversion" => "1.0", "id" => id, "source" => "task-api", "type" => type, "time" => "2026-10-29T12:00:00.000Z", "projectid" => 3, "data" => data }.merge(extra.stringify_keys)
  end

  def sent = ActionMailer::Base.deliveries
end

RSpec.configure do |config|
  config.include EventHelpers
  config.before { ActionMailer::Base.deliveries.clear }
  config.after { Notifications::Heartbeat.reset! }
end
