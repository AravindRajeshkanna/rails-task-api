# Teams of an organization. Everyone in the organization can see them (they can see its members too);
# owners and admins manage them, and manage who is in them (TeamMembershipPolicy).
class TeamPolicy < ApplicationPolicy
  class Scope < Scope
    def resolve
      scope.where(organization_id: OrganizationMembership.where(user_id: user.id).select(:organization_id))
    end
  end

  def index? = actor_role.present?
  def show? = actor_role.present?
  def create? = administrator?
  def update? = administrator?
  def destroy? = administrator?

  private
    def actor_role
      @actor_role ||= OrganizationMembership.where(organization_id: record.organization_id, user_id: user.id).pick(:role)
    end

    def administrator? = actor_role.in?(%w[owner admin])
end
