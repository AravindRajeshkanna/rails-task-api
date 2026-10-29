class TaskPolicy < ApplicationPolicy
  class Scope < Scope
    def resolve
      scope.where(project_id: member_project_ids)
    end
  end

  def index? = member_of?(record.project)
  def show? = visible? && member_of?(record.project)
  def create? = record.project.kept? && member_of?(record.project)
  def update? = visible? && member_of?(record.project)
  def destroy? = visible? && (admin_of?(record.project) || record.creator_id == user.id)
  def restore? = record.discarded? && record.project.kept? && admin_of?(record.project)

  private
    def visible? = record.kept? && record.project.kept?
end
