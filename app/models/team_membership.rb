# A person in a team. They have to be a member of the team's organization.
class TeamMembership < ApplicationRecord
  include Auditable

  belongs_to :team
  belongs_to :user

  validates :user_id, uniqueness: { scope: :team_id, message: "is already in this team" }
  validate :user_belongs_to_organization, on: :create

  audit_destruction

  def audit_organization_id = team.organization_id

  private
    def user_belongs_to_organization
      return unless team && user

      errors.add(:user, "must be a member of the team's organization") unless OrganizationMembership.exists?(organization_id: team.organization_id, user_id: user_id)
    end
end
