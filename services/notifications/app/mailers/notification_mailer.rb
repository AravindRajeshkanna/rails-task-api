# Plain-text emails built entirely from the event's data. Nothing here touches the database.
class NotificationMailer < ApplicationMailer
  def task_assigned(data)
    @task = data.fetch("task")
    @project = data.fetch("project")
    @actor = data["actor"]
    @url = data["url"]
    mail to: recipient(data), subject: "You were assigned: #{clean(@task['title'])}"
  end

  def task_due_soon(data)
    @task = data.fetch("task")
    @project = data.fetch("project")
    @url = data["url"]
    mail to: recipient(data), subject: "Due tomorrow: #{clean(@task['title'])}"
  end

  def password_reset(data)
    @name = data.dig("recipient", "name")
    @reset_url = data.fetch("reset_url")
    @minutes = data["expires_in_minutes"] || 15
    mail to: recipient(data), subject: "Reset your password"
  end

  private
    def recipient(data) = data.dig("recipient", "email_address")

    # Subjects are one line of text, whatever the task title contains.
    def clean(text) = text.to_s.squish.truncate(120)
end
