# A person's own sign-ins, and nobody else's: the list shows where their account is signed in, and any of those can be ended.
class SessionPolicy < ApplicationPolicy
  class Scope < Scope
    def resolve = scope.active.where(user_id: user.id)
  end

  def index? = true
  def destroy? = record.user_id == user.id
end
