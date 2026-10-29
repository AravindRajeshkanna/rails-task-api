# A group of people and the projects they share. See OrganizationMembership for the roles and
# ProjectPolicy for what they grant: owners and admins administer every project of the
# organization without being added to each one; members can create projects in it.
class Organization < ApplicationRecord
  include Auditable

  has_many :organization_memberships, dependent: :destroy
  has_many :members, through: :organization_memberships, source: :user
  has_many :organization_invitations, dependent: :destroy
  # The history of the organization's membership; kept (unlinked) if the organization is deleted, like a project's.
  has_many :audit_events, dependent: :nullify
  # An organization with projects cannot be deleted: its projects would lose their tenant boundary.
  has_many :projects, dependent: :restrict_with_error

  normalizes :name, with: ->(name) { name.squish }

  validates :name, presence: true, length: { maximum: 100 }

  def audit_organization_id = id
end
