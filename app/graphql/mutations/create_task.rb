module Mutations
  class CreateTask < BaseMutation
    description "Create a task in a project you can work in (REST: POST /projects/:id/tasks)"

    argument :project_id, ID
    argument :title, String
    argument :description, String, required: false
    argument :status, Types::TaskStatusEnum, required: false
    argument :priority, Types::TaskPriorityEnum, required: false
    argument :due_on, GraphQL::Types::ISO8601Date, required: false
    argument :assignee_id, ID, required: false, description: "Must be a member of the project"
    argument :tag_names, [ String ], required: false, description: "Unknown names are created"

    field :task, Types::TaskType

    def resolve(project_id:, **attributes)
      project = policy_scope(Project).kept.find_by(id: project_id) or not_found
      task = project.tasks.build(creator: current_user)
      authorize!(task, :create?)
      saving do
        task.assign_attributes(attributes) # after the project is set: tag_names= needs it, as over REST
        task.save!
        { task: task, errors: [] }
      end
    end
  end
end
