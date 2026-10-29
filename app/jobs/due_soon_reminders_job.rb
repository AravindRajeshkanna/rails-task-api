# Emails assignees about unfinished tasks due tomorrow. Scheduled daily in config/recurring.yml.
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
      TaskMailer.due_soon(task).deliver_later
    end
  end
end
