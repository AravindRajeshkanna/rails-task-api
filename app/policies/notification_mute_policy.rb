# Mutes belong to the person who made them. Muting a project needs access to it (checked where the project is looked up), but a mute
# outlives that access: it stays harmless, and still listed so the person can remove it.
class NotificationMutePolicy < ApplicationPolicy
  class Scope < Scope
    def resolve = scope.where(user_id: user.id)
  end

  def index? = true
  def create? = true
  def destroy? = record.user_id == user.id
end
