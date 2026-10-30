# A named group inside an organization (Backend, Design, Support): a way to give a set of people the
# same access to a project in one step. Its members must belong to the organization. Only owners and
# admins of the organization manage teams (TeamPolicy); a team's maintainers manage its plain members (TeamMembershipPolicy).
#
# A team grants access to projects through ProjectTeam; leaving the team ends that access.
#
# Teams nest one level: a team can have a parent ("Engineering" > "Backend"), and the members of a sub-team have what its parent was granted, on
# top of what the sub-team was. Never the other way (granting a project to Backend does not reach the rest of Engineering), and never deeper
# (a sub-team cannot have sub-teams). Everything that decides who gets access through a team asks Team.granting_to / Team.with_sub_teams, so
# the rule is written once.
class Team < ApplicationRecord
  include Auditable

  belongs_to :organization
  belongs_to :parent, class_name: "Team", optional: true
  has_many :sub_teams, class_name: "Team", foreign_key: :parent_id, inverse_of: :parent, dependent: :restrict_with_error
  has_many :team_memberships, dependent: :destroy
  has_many :members, through: :team_memberships, source: :user
  has_many :project_teams, dependent: :destroy
  has_many :projects, through: :project_teams

  normalizes :name, with: ->(name) { name.squish }

  validates :name, presence: true, length: { maximum: 100 }, uniqueness: { scope: :organization_id, case_sensitive: false }
  validate :parent_is_a_top_level_team_of_this_organization, if: -> { parent_id.present? }
  validate :teams_with_sub_teams_stay_top_level, if: -> { parent_id.present? && persisted? }

  audit_destruction

  # The teams whose grants a person has: those they are in, and the parents of those.
  def self.granting_to(user_id)
    in_teams = TeamMembership.where(user_id: user_id).select(:team_id)
    where(id: in_teams).or(where(id: where(id: in_teams).where.not(parent_id: nil).select(:parent_id)))
  end

  # Teams, and their sub-teams: where a grant to the teams in +ids+ (a relation of ids) reaches people.
  def self.with_sub_teams(ids)
    where(id: ids).or(where(parent_id: ids))
  end

  def audit_organization_id = organization_id

  private
    # The same message whether the parent does not exist or is another organization's, so a team id from elsewhere cannot be probed.
    def parent_is_a_top_level_team_of_this_organization
      candidate = Team.find_by(id: parent_id, organization_id: organization_id)
      if candidate.nil? || candidate.id == id
        errors.add(:parent, "must be another team of this organization")
      elsif candidate.parent_id.present?
        errors.add(:parent, "cannot be a sub-team: teams nest one level")
      end
    end

    def teams_with_sub_teams_stay_top_level
      errors.add(:parent, "cannot be set on a team that has sub-teams: teams nest one level") if sub_teams.exists?
    end
end
