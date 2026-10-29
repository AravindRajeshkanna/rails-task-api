# Who may invite people to an organization and withdraw invitations. +record+ is an
# OrganizationInvitation (an existing one, or a new one built from the request, with the role offered).
# Only owners and admins can see invitations at all: they carry email addresses.
#
#   invite / revoke  owners for any role; admins for plain members
class OrganizationInvitationPolicy < ApplicationPolicy
  class Scope < Scope
    def resolve
      scope.where(organization_id: OrganizationMembership.administrators.where(user_id: user.id).select(:organization_id))
    end
  end

  def index? = actor_role.in?(%w[owner admin])

  def create?
    actor_role == "owner" || (actor_role == "admin" && record.member?)
  end

  def destroy? = create?

  private
    def actor_role
      @actor_role ||= OrganizationMembership.where(organization_id: record.organization_id, user_id: user.id).pick(:role)
    end
end
