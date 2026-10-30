module Mutations
  class MarkNotificationRead < BaseMutation
    description "Mark one of your notifications read, or unread again with read: false. Idempotent (REST: PATCH /notifications/:id)"

    argument :id, ID
    argument :read, Boolean, required: false, default_value: true

    field :notification, Types::NotificationType

    def resolve(id:, read:)
      notification = policy_scope(Notification).find_by(id: id) or not_found
      authorize!(notification, :update?)
      { notification: notification.mark_read!(read: read), errors: [] }
    end
  end
end
