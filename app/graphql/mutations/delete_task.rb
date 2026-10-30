module Mutations
  class DeleteTask < BaseMutation
    description "Delete a task: a soft delete, restorable by an administrator over REST (REST: DELETE /tasks/:id)"

    argument :id, ID

    field :deleted_task_id, ID

    def resolve(id:)
      task = policy_scope(Task).kept.find_by(id: id) or not_found
      authorize!(task, :destroy?)
      task.discard
      { deleted_task_id: task.id, errors: [] }
    end
  end
end
