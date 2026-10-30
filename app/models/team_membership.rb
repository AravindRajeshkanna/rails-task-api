# A person in a team. They have to be a member of the team's organization. A maintainer can manage the plain members of the team (see
# TeamMembershipPolicy); the role grants no project access, which comes only from what the team was granted.
class TeamMembership < ApplicationRecord
  include Auditable

  belongs_to :team
  belongs_to :user
  enum :role, { member: "member", maintainer: "maintainer" }, default: :member, validate: true

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
