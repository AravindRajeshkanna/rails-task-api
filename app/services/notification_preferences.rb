# What a batch of people have asked for, loaded in two queries so a job that visits thousands of tasks does not ask once per task.
#
#   preferences = NotificationPreferences.new(tasks.map(&:assignee_id))
#   preferences.inbox?(user_id, "task.assigned", project_id)   # false if they muted it
#   preferences.email?(user_id, "task.due_soon", project_id)   # false if muted, or if they take a daily digest instead
class NotificationPreferences
  def initialize(user_ids)
    ids = Array(user_ids).compact.uniq
    @settings = NotificationSetting.where(user_id: ids).index_by(&:user_id)
    @mutes = NotificationMute.where(user_id: ids).group_by(&:user_id)
  end

  def inbox?(user_id, kind, project_id) = !muted?(user_id, kind, project_id)

  def email?(user_id, kind, project_id) = !muted?(user_id, kind, project_id) && !@settings[user_id]&.daily?

  private
    def muted?(user_id, kind, project_id) = @mutes.fetch(user_id, []).any? { |mute| mute.covers?(kind, project_id) }
end
