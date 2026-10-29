class ProjectPolicy < ApplicationPolicy
  class Scope < Scope
    # Projects the user belongs to (kept and discarded), annotated with the user's role as
    # +current_role+: the highest of their own membership, their teams' access, and admin through
    # owning/administering the project's organization. Callers narrow with +.kept+ / +.discarded+.
    #
    # Each join yields at most one row per project (a user has one membership per project and per
    # organization, and the team grants are grouped per project), so a project never appears twice.
    TEAM_ACCESS = <<~SQL.squish.freeze
      LEFT JOIN (
        SELECT project_teams.project_id,
               CASE WHEN bool_or(project_teams.role = 'admin') THEN 'admin' ELSE 'member' END AS role
        FROM project_teams
        JOIN team_memberships ON team_memberships.team_id = project_teams.team_id AND team_memberships.user_id = ?
        GROUP BY project_teams.project_id
      ) team_access ON team_access.project_id = projects.id
    SQL

    def resolve
      scope.joins(sanitize("LEFT JOIN memberships ON memberships.project_id = projects.id AND memberships.user_id = ?"))
           .joins(sanitize("LEFT JOIN organization_memberships administered ON administered.organization_id = projects.organization_id " \
                           "AND administered.user_id = ? AND administered.role IN ('owner', 'admin')"))
           .joins(sanitize(TEAM_ACCESS))
           .where("memberships.id IS NOT NULL OR administered.id IS NOT NULL OR team_access.project_id IS NOT NULL")
           .select("projects.*", <<~SQL.squish)
             CASE WHEN administered.id IS NOT NULL OR memberships.role = 'admin' OR team_access.role = 'admin' THEN 'admin'
                  ELSE 'member' END AS current_role
           SQL
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
