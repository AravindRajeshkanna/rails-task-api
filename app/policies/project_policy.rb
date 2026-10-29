class ProjectPolicy < ApplicationPolicy
  class Scope < Scope
    # Projects the user belongs to (kept and discarded), annotated with the user's role as
    # +current_role+: their own membership, or admin through owning/administering the project's
    # organization. Callers narrow with +.kept+ / +.discarded+.
    #
    # Both joins match at most one row (a user has one membership per project and per organization),
    # so a project never appears twice.
    def resolve
      scope.joins(sanitize("LEFT JOIN memberships ON memberships.project_id = projects.id AND memberships.user_id = ?"))
           .joins(sanitize("LEFT JOIN organization_memberships administered ON administered.organization_id = projects.organization_id " \
                           "AND administered.user_id = ? AND administered.role IN ('owner', 'admin')"))
           .where("memberships.id IS NOT NULL OR administered.id IS NOT NULL")
           .select("projects.*", "CASE WHEN administered.id IS NOT NULL THEN 'admin' ELSE memberships.role END AS current_role")
    end

    private
      def sanitize(sql) = Project.sanitize_sql_array([ sql, user.id ])
  end

  def index? = true
  def create? = true
  def show? = record.kept? && member_of?(record)
  def update? = record.kept? && admin_of?(record)
  def destroy? = record.kept? && (owner? || organization_owner?)
  def restore? = record.discarded? && (owner? || organization_owner?)

  # Project-level administration that other resources defer to.
  def analytics? = show?
  def audit? = update?
  def manage_webhooks? = update?

  private
    def owner? = record.owner_id == user.id

    # Owners of the organization may delete and restore its projects, not just the project's own owner.
    def organization_owner?
      record.organization_id.present? &&
        OrganizationMembership.owner.exists?(organization_id: record.organization_id, user_id: user.id)
    end
end
