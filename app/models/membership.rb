class Membership < ApplicationRecord
  include Auditable

  belongs_to :project
  belongs_to :user

  NOT_IN_ORGANIZATION = "must be a member of the project's organization".freeze

  enum :role, { member: "member", admin: "admin" }, default: :member, validate: true

  validates :user_id, uniqueness: { scope: :project_id, message: "is already a member of this project" }
  validate :owner_remains_admin, on: :update
  validate :user_belongs_to_organization, on: :create

  before_destroy :prevent_removing_owner, prepend: true
  audit_destruction

  def audit_project_id = project_id

  def owner? = project.owner_id == user_id

  private
    # The tenant boundary: a project of an organization only takes members of that organization.
    def user_belongs_to_organization
      return unless project&.organization_id && user

      unless OrganizationMembership.exists?(organization_id: project.organization_id, user_id: user_id)
        errors.add(:user, NOT_IN_ORGANIZATION)
      end
    end

    def owner_remains_admin
      errors.add(:role, "of the project owner cannot be changed") if owner? && !admin?
    end

    def prevent_removing_owner
      return unless owner? && !destroyed_by_association

      errors.add(:base, "The project owner cannot be removed")
      throw :abort
    end
end
