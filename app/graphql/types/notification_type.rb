module Types
  class NotificationType < BaseObject
    graphql_name "Notification"

    field :id, ID, null: false
    field :kind, String, null: false, description: "task.assigned, task.due_soon, task.completed or comment.created"
    field :project_id, ID, null: false
    field :task_id, ID, null: false
    field :data, GraphQL::Types::JSON, null: false, description: "A snapshot: task_title, project_name and as relevant due_on and comment_excerpt"
    field :read, Boolean, null: false
    field :read_at, GraphQL::Types::ISO8601DateTime
    field :created_at, GraphQL::Types::ISO8601DateTime, null: false
    field :actor, UserType

    def read = object.read?
    def actor = dataload_association(:actor)
  end
end
