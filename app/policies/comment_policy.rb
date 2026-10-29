class CommentPolicy < ApplicationPolicy
  class Scope < Scope
    def resolve
      scope.joins(:task).where(tasks: { project_id: member_project_ids })
    end
  end

  def index? = member_of?(project)
  def create? = member_of?(project)
  def update? = record.user_id == user.id
  def destroy? = record.user_id == user.id || admin_of?(project)

  private
    def project = record.task.project
end
