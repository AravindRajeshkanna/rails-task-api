# Reminds assignees about unfinished tasks due tomorrow. Scheduled daily in config/recurring.yml.
# Each reminder is a task.due_soon event; with NOTIFICATIONS_MODE=local this app also sends the email,
# otherwise the Notification service does.
class DueSoonRemindersJob < ApplicationJob
  queue_as :default

  def perform
    Task.kept
        .where(due_on: Date.tomorrow)
        .where.not(status: :done)
        .where.not(assignee_id: nil)
        .where(project_id: Project.kept.select(:id))
        .includes(:assignee, :project)
        .find_each do |task|
      Rails.event.notify("task.due_soon", subject: task.to_global_id.to_s, project_id: task.project_id)
      TaskMailer.due_soon(task).deliver_later if Rails.configuration.x.notifications.mode == "local"
    end
  end
end
