class Membership < ApplicationRecord
  include Auditable

  belongs_to :project
  belongs_to :user

  enum :role, { member: "member", admin: "admin" }, default: :member, validate: true

  validates :user_id, uniqueness: { scope: :project_id, message: "is already a member of this project" }
  validate :owner_remains_admin, on: :update

  before_destroy :prevent_removing_owner, prepend: true

  def audit_project_id = project_id

  def owner? = project.owner_id == user_id

  private
    def owner_remains_admin
      errors.add(:role, "of the project owner cannot be changed") if owner? && !admin?
    end

    def prevent_removing_owner
      return unless owner? && !destroyed_by_association

      errors.add(:base, "The project owner cannot be removed")
      throw :abort
    end
end
