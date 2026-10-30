# Keeps the inbox from growing for ever: read notifications go after 30 days, unread ones after 180.
# Scheduled daily in config/recurring.yml.
class PurgeNotificationsJob < ApplicationJob
  READ_RETENTION = 30.days
  UNREAD_RETENTION = 180.days

  queue_as :low

  def perform
    Notification.read.where(read_at: ..READ_RETENTION.ago).in_batches.delete_all
    Notification.where(created_at: ..UNREAD_RETENTION.ago).in_batches.delete_all
  end
end
