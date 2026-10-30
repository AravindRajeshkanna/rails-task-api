module Types
  class QueryType < BaseObject
    graphql_name "Query"

    field :me, ViewerType, null: false, description: "The signed-in person"
    field :projects, ProjectType.connection_type, null: false, description: "Projects you belong to (directly, through a team, or by administering their organization), newest first" do
      argument :organization_id, ID, required: false
    end
    field :project, ProjectType, description: "Null if it does not exist or you cannot see it" do
      argument :id, ID
    end
    field :task, TaskType, description: "Null if it does not exist or you cannot see it" do
      argument :id, ID
    end
    field :search, SearchResultType.connection_type, null: false, description: "Full-text search of tasks across your projects, best match first" do
      argument :query, String, description: "Words are stemmed; \"quoted phrases\", or and -excluded work. At most 200 characters"
      argument :project_id, ID, required: false
    end
    field :notifications, NotificationType.connection_type, null: false, description: "Your inbox, newest first" do
      argument :unread, Boolean, required: false
    end
    field :unread_notifications_count, Integer, null: false

    def me = current_user

    def projects(organization_id: nil)
      scope = policy_scope(Project).kept.order(created_at: :desc, id: :desc)
      organization_id ? scope.where(organization_id: organization_id) : scope
    end

    def project(id:) = policy_scope(Project).kept.find_by(id: id)

    def task(id:) = policy_scope(Task).kept.find_by(id: id)

    def search(query:, project_id: nil) = TaskSearch.new(policy_scope(Task), query, project_id: project_id).call

    def notifications(unread: nil)
      scope = policy_scope(Notification).newest_first
      unread ? scope.unread : scope
    end

    def unread_notifications_count = policy_scope(Notification).unread.count
  end
end
