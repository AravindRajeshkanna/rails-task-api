# Who may see and change an organization. Roles are on OrganizationMembership.
class OrganizationPolicy < ApplicationPolicy
  class Scope < Scope
    # Organizations the user belongs to, annotated with their role as +current_role+.
    def resolve
      scope.joins(:organization_memberships)
           .where(organization_memberships: { user_id: user.id })
           .select("organizations.*", "organization_memberships.role AS current_role")
    end
  end

  def index? = true
  def create? = true
  def show? = member?
  def update? = administrator?
  def destroy? = role == "owner"
  # The organization's history (who joined, was promoted, invited, removed). Owners only.
  def audit? = role == "owner"

  # Whether +record+ (an Organization) may have projects created in it by this user.
  def create_project? = member?

  private
    def role
      @role ||= record.try(:current_role) || OrganizationMembership.where(organization_id: record.id, user_id: user.id).pick(:role)
    end

    def member? = role.present?
    def administrator? = role.in?(%w[owner admin])
end
