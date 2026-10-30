# Who is in a team. +record+ is a TeamMembership. Visible to the organization. Owners and admins of the organization manage it all,
# including who maintains the team; a maintainer of the team adds and removes its plain members, and nothing else: not other
# maintainers, not roles, not themselves (leaving is an administrator's act, as for every plain member).
class TeamMembershipPolicy < ApplicationPolicy
  class Scope < Scope
    def resolve
      scope.where(team_id: Team.where(organization_id: OrganizationMembership.where(user_id: user.id).select(:organization_id)).select(:id))
    end
  end

  def index? = actor_role.present?
  def create? = administrator? || (maintainer? && record.member?)
  def update? = administrator? # changing a role
  def destroy? = administrator? || (maintainer? && record.member?)

  private
    def actor_role
      @actor_role ||= OrganizationMembership.where(organization_id: record.team.organization_id, user_id: user.id).pick(:role)
    end

    def administrator? = actor_role.in?(%w[owner admin])

    def maintainer?
      return @maintainer if defined?(@maintainer)

      @maintainer = actor_role.present? && TeamMembership.maintainer.exists?(team_id: record.team_id, user_id: user.id)
    end
end
