# Who is in a team. +record+ is a TeamMembership. Visible to the organization; changed by its owners and admins.
class TeamMembershipPolicy < ApplicationPolicy
  class Scope < Scope
    def resolve
      scope.where(team_id: Team.where(organization_id: OrganizationMembership.where(user_id: user.id).select(:organization_id)).select(:id))
    end
  end

  def index? = actor_role.present?
  def create? = administrator?
  def destroy? = administrator?

  private
    def actor_role
      @actor_role ||= OrganizationMembership.where(organization_id: record.team.organization_id, user_id: user.id).pick(:role)
    end

    def administrator? = actor_role.in?(%w[owner admin])
end
