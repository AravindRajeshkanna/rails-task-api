class MembershipPolicy < ApplicationPolicy
  class Scope < Scope
    def resolve
      scope.where(project_id: member_project_ids)
    end
  end

  def index? = member_of?(record.project)
  def create? = admin_of?(record.project)
  def update? = admin_of?(record.project)
  # Admins remove anyone; members can leave. (The owner is protected by the model.)
  def destroy? = admin_of?(record.project) || record.user_id == user.id
end
