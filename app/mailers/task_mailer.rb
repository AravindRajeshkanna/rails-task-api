class TaskMailer < ApplicationMailer
  def assigned(task)
    @task = task
    @url = task_url(task)
    mail subject: "You were assigned: #{task.title}", to: task.assignee.email_address
  end

  def due_soon(task)
    @task = task
    @url = task_url(task)
    mail subject: "Due tomorrow: #{task.title}", to: task.assignee.email_address
  end

  private
    def task_url(task) = frontend_url("/projects/#{task.project_id}/tasks/#{task.id}")
end
