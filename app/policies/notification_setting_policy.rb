# Your notification settings are yours alone: there is one row per person, and no way to name anyone else's.
class NotificationSettingPolicy < ApplicationPolicy
  def show? = record.user_id == user.id
  def update? = record.user_id == user.id
end
