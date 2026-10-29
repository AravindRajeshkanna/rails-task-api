# A user's role in an organization.
#
#   owner   everything, including deleting the organization and granting any role
#   admin   administers every project of the organization; can add and remove plain members
#   member  can see the organization and create projects in it
#
# The organization always keeps at least one owner.
class OrganizationMembership < ApplicationRecord
  include Auditable

  belongs_to :organization
  belongs_to :user

  enum :role, { member: "member", admin: "admin", owner: "owner" }, default: :member, validate: true

  validates :user_id, uniqueness: { scope: :organization_id, message: "is already a member of this organization" }
  validate :organization_keeps_an_owner, on: :update

  before_destroy :prevent_removing_last_owner, prepend: true
  audit_destruction
  # Leaving the organization means leaving its teams, wherever the removal came from.
  after_destroy :leave_teams, unless: :destroyed_by_association

  # Owners and admins; the roles that administer the organization's projects.
  scope :administrators, -> { where(role: %w[owner admin]) }

  def audit_organization_id = organization_id

  private
    def organization_keeps_an_owner
      return unless role_changed? && role_was == "owner" && !owner?

      errors.add(:role, "cannot be changed: the organization needs at least one owner") if last_owner?
    end

    def prevent_removing_last_owner
      return unless owner? && last_owner? && !destroyed_by_association

      errors.add(:base, "The last owner cannot leave; make someone else an owner first")
      throw :abort
    end

    def leave_teams
      TeamMembership.where(user_id: user_id, team_id: organization.teams.select(:id)).destroy_all
    end

    def last_owner? = !organization.organization_memberships.owner.where.not(id: id).exists?
end
