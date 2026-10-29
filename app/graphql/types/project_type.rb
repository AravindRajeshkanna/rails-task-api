module Types
  class ProjectType < BaseObject
    graphql_name "Project"

    field :id, ID, null: false
    field :name, String, null: false
    field :description, String
    field :organization_id, ID
    field :created_at, GraphQL::Types::ISO8601DateTime, null: false
    field :updated_at, GraphQL::Types::ISO8601DateTime, null: false
    field :role, String, description: "The caller's role in the project (admin or member). Null where it was not looked up (a project reached through a task)."
    field :owner, UserType, null: false
    field :tasks, TaskType.connection_type, null: false, description: "Newest first, unless `sort` or `search` says otherwise" do
      argument :status, [ TaskStatusEnum ], required: false
      argument :priority, [ TaskPriorityEnum ], required: false
      argument :assignee, String, required: false, description: "`me`, `unassigned` or a user id"
      argument :tag, [ String ], required: false
      argument :overdue, Boolean, required: false
      argument :search, String, required: false, description: "Full-text; best match first unless `sort` is given"
      argument :sort, String, required: false, description: "As REST: comma-separated columns, `-` for descending"
    end

    def role = object.try(:current_role)
    def owner = dataload_association(:owner)

    def tasks(status: nil, priority: nil, assignee: nil, tag: nil, overdue: nil, search: nil, sort: nil)
      params = { status: status&.join(","), priority: priority&.join(","), assignee: assignee, tag: tag&.join(","), overdue: overdue&.to_s, search: search, sort: sort }.compact
      TaskQuery.new(policy_scope(object.tasks).kept, params, current_user: current_user).call
    end
  end
end
