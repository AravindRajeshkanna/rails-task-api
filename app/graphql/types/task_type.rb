module Types
  class TaskType < BaseObject
    graphql_name "Task"

    field :id, ID, null: false
    field :project_id, ID, null: false
    field :title, String, null: false
    field :description, String
    field :status, TaskStatusEnum, null: false
    field :priority, TaskPriorityEnum, null: false
    field :due_on, GraphQL::Types::ISO8601Date
    field :overdue, Boolean, null: false
    field :completed_at, GraphQL::Types::ISO8601DateTime
    field :comments_count, Integer, null: false
    field :lock_version, Integer, null: false, description: "Send it back when updating over REST (optimistic locking)"
    field :created_at, GraphQL::Types::ISO8601DateTime, null: false
    field :updated_at, GraphQL::Types::ISO8601DateTime, null: false
    field :creator, UserType, null: false
    field :assignee, UserType
    field :tags, [ String ], null: false
    field :project, "Types::ProjectType", null: false
    field :comments, CommentType.connection_type, null: false, description: "Oldest first"

    def overdue = object.overdue?
    def creator = dataload_association(:creator)
    def assignee = dataload_association(:assignee)
    def project = dataload_association(:project)
    def tags = dataload_association(:tags).map(&:name).sort
    def comments = policy_scope(object.comments).order(:created_at, :id)
  end
end
