class TagPolicy < ApplicationPolicy
  class Scope < Scope
    def resolve
      scope.where(project_id: member_project_ids)
    end
  end

  def index? = member_of?(record.project)
  def create? = member_of?(record.project)
  def destroy? = admin_of?(record.project)
end
