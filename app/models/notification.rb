# One item in a person's inbox: something that happened that they should know about.
#
#   task.assigned    a task was given to you by someone else
#   task.due_soon    a task of yours is due tomorrow and not done
#   task.completed   someone else completed a task you created
#   comment.created  someone else commented on a task you created or are assigned
#
# Written by Events::InboxSubscriber from the same domain events the Notification service turns into
# email and Slack, read through NotificationPolicy (which also hides what is in a project you have
# since left). Pruned by PurgeNotificationsJob.
class Notification < ApplicationRecord
  KINDS = %w[task.assigned task.due_soon task.completed comment.created].freeze

  belongs_to :user
  belongs_to :project
  belongs_to :task
  belongs_to :actor, class_name: "User", optional: true

  validates :kind, inclusion: { in: KINDS }

  scope :unread, -> { where(read_at: nil) }
  scope :read, -> { where.not(read_at: nil) }
  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  # Pushed to the recipient's open connections (NotificationsChannel) as soon as it is stored.
  after_create_commit :broadcast

  def self.stream_name(user_id) = "notifications:#{user_id}"

  def read? = read_at.present?

  def mark_read!(read: true)
    update!(read_at: read ? (read_at || Time.current) : nil)
    self
  end

  private
    def broadcast
      ActionCable.server.broadcast(self.class.stream_name(user_id), {
        event: "notification.created", occurred_at: created_at.utc.iso8601(3), data: NotificationResource.new(self).serializable_hash
      })
    end
end
