# Sends each person who chose a daily digest (NotificationSetting) one email with what is new and unread in their inbox. Runs hourly; a
# person's summary goes out in the hour they chose in their own time zone, at most once a day. Whatever they muted was never written to
# the inbox, and what they can no longer see is left out (NotificationPolicy), so the digest needs no filtering of its own.
class NotificationDigestJob < ApplicationJob
  queue_as :default

  FALLBACK_WINDOW = 24.hours # for a first summary, how far back to look

  def perform(now = Time.current)
    NotificationSetting.daily.includes(:user).find_each do |setting|
      send_digest(setting, now) if setting.digest_due?(now)
    end
  end

  private
    def send_digest(setting, now)
      setting.with_lock do
        next unless setting.digest_due?(now) # another run got here first

        items = items_for(setting.user, setting.last_digest_at || (now - FALLBACK_WINDOW))
        NotificationDigestMailer.daily(setting.user, items).deliver_later if items.any?
        setting.update!(last_digest_at: now)
      end
    end

    def items_for(user, since)
      NotificationPolicy::Scope.new(user, Notification).resolve
                               .unread.where(created_at: since..).includes(:project, :task).newest_first.limit(100)
                               .map do |notification|
        { "kind" => notification.kind, "project_id" => notification.project_id, "project_name" => notification.project.name,
          "task_id" => notification.task_id, "task_title" => notification.data["task_title"] || notification.task.title,
          "comment_excerpt" => notification.data["comment_excerpt"] }.compact
      end
    end
end
