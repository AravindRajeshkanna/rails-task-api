class ProjectPolicy < ApplicationPolicy
  class Scope < Scope
    # Projects the user belongs to (kept and discarded), annotated with the
    # user's role as +current_role+. Callers narrow with +.kept+ / +.discarded+.
    def resolve
      scope.joins(:memberships)
           .where(memberships: { user_id: user.id })
           .select("projects.*", "memberships.role AS current_role")
    end
  end

  def index? = true
  def create? = true
  def show? = record.kept? && member_of?(record)
  def update? = record.kept? && admin_of?(record)
  def destroy? = record.kept? && owner?
  def restore? = record.discarded? && owner?

  # Project-level administration that other resources defer to.
  def audit? = update?
  def manage_webhooks? = update?

  private
    def owner? = record.owner_id == user.id
end
