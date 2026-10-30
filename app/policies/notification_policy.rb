# A notification is its recipient's alone. What it is about must still be visible to them: after
# leaving a project (or its being archived) its notifications disappear from the inbox with the access.
class NotificationPolicy < ApplicationPolicy
  class Scope < Scope
    def resolve
      scope.where(user_id: user.id, project_id: member_project_ids)
    end
  end

  def index? = true
  def read_all? = true
  def update? = record.user_id == user.id
  def destroy? = record.user_id == user.id
end
