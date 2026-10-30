# The daily summary for people who chose NotificationSetting#digest = "daily" (built and queued by NotificationDigestJob). It gets plain
# hashes, not records, so a notification pruned before the mail is rendered cannot fail the job.
class NotificationDigestMailer < ApplicationMailer
  LABELS = {
    "task.assigned" => "assigned to you", "task.due_soon" => "due tomorrow",
    "task.completed" => "completed", "comment.created" => "new comment"
  }.freeze

  def daily(user, items)
    @user = user
    @by_project = items.group_by { |item| item.fetch("project_name") }
    @count = items.size
    @settings_url = frontend_url("/settings/notifications")
    @labels = LABELS
    mail subject: "Your daily summary: #{@count} #{'update'.pluralize(@count)}", to: user.email_address
  end

  # A link to the task an item is about.
  helper_method def task_link(item) = frontend_url("/projects/#{item.fetch('project_id')}/tasks/#{item.fetch('task_id')}")
end
