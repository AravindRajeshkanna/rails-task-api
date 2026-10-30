# A named group inside an organization (Backend, Design, Support): a way to give a set of people the
# same access to a project in one step. Its members must belong to the organization. Only owners and
# admins of the organization manage teams (TeamPolicy).
#
# A team grants access to projects through ProjectTeam; leaving the team ends that access.
class Team < ApplicationRecord
  include Auditable

  belongs_to :organization

  has_many :team_memberships, dependent: :destroy
  has_many :members, through: :team_memberships, source: :user
  has_many :project_teams, dependent: :destroy
  has_many :projects, through: :project_teams

  normalizes :name, with: ->(name) { name.squish }

  validates :name, presence: true, length: { maximum: 100 }, uniqueness: { scope: :organization_id, case_sensitive: false }

  audit_destruction

  def audit_organization_id = organization_id
end
