# A team's access to a project, with the role every member of the team gets there (member or admin).
# Added up with the person's other routes in: a direct membership, or administering the organization.
# The highest role wins. Only a project of the team's own organization can be granted.
class ProjectTeam < ApplicationRecord
  include Auditable

  belongs_to :project
  belongs_to :team

  enum :role, { member: "member", admin: "admin" }, default: :member, validate: true

  validates :team_id, uniqueness: { scope: :project_id, message: "already has access to this project" }
  validate :team_belongs_to_projects_organization, on: :create

  audit_destruction

  def audit_project_id = project_id
  def audit_organization_id = team.organization_id

  private
    def team_belongs_to_projects_organization
      return unless project && team

      errors.add(:team, "must belong to the project's organization") unless project.organization_id == team.organization_id
    end
end
