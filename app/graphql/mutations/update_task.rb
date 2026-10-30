module Mutations
  class UpdateTask < BaseMutation
    description "Change a task (REST: PATCH /tasks/:id). Only the arguments you send change; send null to clear a description, a due date or an assignee"

    argument :id, ID
    argument :title, String, required: false
    argument :description, String, required: false
    argument :status, Types::TaskStatusEnum, required: false
    argument :priority, Types::TaskPriorityEnum, required: false
    argument :due_on, GraphQL::Types::ISO8601Date, required: false
    argument :assignee_id, ID, required: false, description: "Must be a member of the project"
    argument :tag_names, [ String ], required: false, description: "Replaces the task's tags"
    argument :lock_version, Integer, required: false, description: "Send the lockVersion you read: a stale one is a stale_object error and nothing changes"

    field :task, Types::TaskType

    def resolve(id:, **attributes)
      task = policy_scope(Task).kept.find_by(id: id) or not_found
      authorize!(task, :update?)
      saving do
        task.update!(attributes)
        { task: task, errors: [] }
      end
    end
  end
end
