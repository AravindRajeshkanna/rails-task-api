module Mutations
  class CreateComment < BaseMutation
    description "Comment on a task you can see (REST: POST /tasks/:id/comments)"

    argument :task_id, ID
    argument :body, String

    field :comment, Types::CommentType

    def resolve(task_id:, body:)
      task = policy_scope(Task).kept.find_by(id: task_id) or not_found
      comment = task.comments.build(user: current_user)
      authorize!(comment, :create?)
      saving do
        comment.update!(body: body)
        { comment: comment, errors: [] }
      end
    end
  end
end
