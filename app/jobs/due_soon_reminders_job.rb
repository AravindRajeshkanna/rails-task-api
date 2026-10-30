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
        .find_in_batches do |tasks|
      preferences = NotificationPreferences.new(tasks.map(&:assignee_id))
      tasks.each { |task| remind(task, preferences) }
    end
  end

  private
    def remind(task, preferences)
      # A fixed id per task and due date: running the job twice records each reminder once.
      Events::Outbox.record("task.due_soon", subject: task, project_id: task.project_id,
                                              id: Digest::UUID.uuid_v5(Digest::UUID::URL_NAMESPACE, "task-api/due_soon/#{task.id}/#{task.due_on}"))
      Rails.event.notify("task.due_soon", subject: task.to_global_id.to_s, project_id: task.project_id)
      return unless Rails.configuration.x.notifications.mode == "local" && preferences.email?(task.assignee_id, "task.due_soon", task.project_id)

      TaskMailer.due_soon(task).deliver_later
    end
end
