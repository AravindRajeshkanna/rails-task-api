module Types
  class MutationType < BaseObject
    graphql_name "Mutation"

    field :create_task, mutation: Mutations::CreateTask
    field :update_task, mutation: Mutations::UpdateTask
    field :delete_task, mutation: Mutations::DeleteTask
    field :create_comment, mutation: Mutations::CreateComment
    field :mark_notification_read, mutation: Mutations::MarkNotificationRead
  end
end
