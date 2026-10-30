# Default-deny. Every policy answers questions about a user's role *within a
# project*: members can work with tasks, admins manage the project, and only the
# owner can delete it.
#
# A person's role in a project is the highest of three routes in (see Scope#member_project_ids and
# #role_in): their own membership, a team they are in that was granted the project (ProjectTeam), and,
# as admin, owning or administering the project's organization, whether or not they were added to the
# project itself. Plain organization members get nothing automatically: projects are private to their
# own members and teams unless an organization administrator steps in.
class ApplicationPolicy
  attr_reader :user, :record

  def initialize(user, record)
    @user = user
    @record = record
  end

  def index? = false
  def show? = false
  def create? = false
  def update? = false
  def destroy? = false

  class Scope
    attr_reader :user, :scope

    def initialize(user, scope)
      @user = user
      @scope = scope
    end

    def resolve
      raise NotImplementedError, "#{self.class} must implement #resolve"
    end

    private
      # Ids of the non-discarded projects the user belongs to (optionally only as +role+), including
      # those their teams were granted and, as admin, every project of an organization the user owns or administers.
      # Child resources are scoped through this, so everything inside a discarded project
      # is a 404 until the project is restored.
      def member_project_ids(role: nil)
        ids = Project.where(id: direct_project_ids(role)).or(Project.kept.where(id: team_project_ids(role)))

        if role.nil? || role.to_s == "admin"
          administered = OrganizationMembership.administrators.where(user_id: user.id).select(:organization_id)
          ids = ids.or(Project.kept.where(organization_id: administered))
        end
        ids.select(:id)
      end

      def direct_project_ids(role)
        direct = Membership.joins(:project).merge(Project.kept).where(user_id: user.id)
        direct = direct.where(role: role) if role
        direct.select(:project_id)
      end

      # Projects granted to a team the user is in (with +role+, if given, as the team's role).
      def team_project_ids(role)
        granted = ProjectTeam.where(team_id: TeamMembership.where(user_id: user.id).select(:team_id))
        granted = granted.where(role: role) if role
        granted.select(:project_id)
      end
  end

  private
    # Role of the current user in +project+ ("admin", "member" or nil): the highest of their routes in.
    # Reuses the +current_role+ column selected by ProjectPolicy::Scope when it is present.
    def role_in(project)
      @roles ||= {}
      @roles.fetch(project.id) do
        @roles[project.id] = project.try(:current_role) || highest_role(
          Membership.where(project_id: project.id, user_id: user.id).pick(:role),
          role_through_team(project),
          role_through_organization(project)
        )
      end
    end

    def highest_role(*roles)
      roles.compact!
      "admin".in?(roles) ? "admin" : roles.first
    end

    # The highest role among the teams the user is in that were granted the project, nil if none.
    def role_through_team(project)
      return unless project.organization_id

      roles = ProjectTeam.where(project_id: project.id, team_id: TeamMembership.where(user_id: user.id).select(:team_id)).pluck(:role)
      highest_role(*roles)
    end

    # "admin" for the owners and admins of the project's organization, nil for everyone else.
    def role_through_organization(project)
      return unless project.organization_id

      administers = OrganizationMembership.administrators.exists?(organization_id: project.organization_id, user_id: user.id)
      "admin" if administers
    end

    def member_of?(project) = role_in(project).present?
    def admin_of?(project) = role_in(project) == "admin"
end
