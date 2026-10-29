# Managing who is in an organization. +record+ is an OrganizationMembership (an existing one, or a
# new one built from the request, with the role being granted).
#
#   add     owners grant any role; admins add plain members
#   change  owners only (admins cannot promote themselves or each other)
#   remove  owners remove anyone; admins remove plain members; anyone can leave
class OrganizationMembershipPolicy < ApplicationPolicy
  class Scope < Scope
    def resolve
      scope.where(organization_id: OrganizationMembership.where(user_id: user.id).select(:organization_id))
    end
  end

  def index? = actor_role.present?

  def create?
    actor_role == "owner" || (actor_role == "admin" && record.member?)
  end

  def update? = actor_role == "owner"

  def destroy?
    return true if record.user_id == user.id
    return true if actor_role == "owner"

    actor_role == "admin" && record.member?
  end

  private
    def actor_role
      @actor_role ||= OrganizationMembership.where(organization_id: record.organization_id, user_id: user.id).pick(:role)
    end
end
