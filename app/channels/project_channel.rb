# Real-time task and comment events for one project.
#
#   subscribe: { channel: "ProjectChannel", project_id: 1 }
#   receive:   { event: "task.updated", occurred_at: "...", data: { ...TaskResource... } }
class ProjectChannel < ApplicationCable::Channel
  def self.stream_name(project_id) = "project:#{project_id}"

  def subscribed
    project = Project.kept.find_by(id: params[:project_id])

    if project && ProjectPolicy.new(current_user, project).show?
      stream_from self.class.stream_name(project.id)
    else
      reject
    end
  end
end
