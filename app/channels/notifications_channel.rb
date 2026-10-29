# A person's own inbox, live: each new notification arrives as it is stored.
#
#   subscribe: { channel: "NotificationsChannel" }
#   receive:   { event: "notification.created", occurred_at: "...", data: { id: 1, kind: "task.assigned", ... } }
#              (data has the shape of an item of GET /notifications)
class NotificationsChannel < ApplicationCable::Channel
  def subscribed
    stream_from Notification.stream_name(current_user.id)
  end
end
