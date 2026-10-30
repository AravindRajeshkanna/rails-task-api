# A team's access to a project. Anyone in the project can see which teams have it; project admins
# (the owner, admins, organization admins, and teams granted admin) grant, change and withdraw it.
# +record+ is a ProjectTeam.
class ProjectTeamPolicy < ApplicationPolicy
  class Scope < Scope
    def resolve
      scope.where(project_id: member_project_ids)
    end
  end

  def index? = member_of?(record.project)
  def create? = manage?
  def update? = manage?
  def destroy? = manage?

  private
    def manage? = record.project.kept? && admin_of?(record.project)
end
