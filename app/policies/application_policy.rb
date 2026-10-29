# Default-deny. Every policy answers questions about a user's role *within a
# project*: members can work with tasks, admins manage the project, and only the
# owner can delete it.
#
# A project that belongs to an organization is also administered by that organization's owners
# and admins, whether or not they were added to the project itself (see Scope#member_project_ids
# and #role_in). Plain organization members get nothing automatically: projects are private
# to their own members unless an organization administrator steps in.
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
      # Ids of the non-discarded projects the user belongs to (optionally only as +role+), including,
      # as admin, every project of an organization the user owns or administers.
      # Child resources are scoped through this, so everything inside a discarded project
      # is a 404 until the project is restored.
      def member_project_ids(role: nil)
        direct = Membership.joins(:project).merge(Project.kept).where(user_id: user.id)
        direct = direct.where(role: role) if role
        ids = Project.where(id: direct.select(:project_id))

        if role.nil? || role.to_s == "admin"
          administered = OrganizationMembership.administrators.where(user_id: user.id).select(:organization_id)
          ids = ids.or(Project.kept.where(organization_id: administered))
        end
        ids.select(:id)
      end
  end

  private
    # Role of the current user in +project+ ("admin", "member" or nil). Reuses the
    # +current_role+ column selected by ProjectPolicy::Scope when it is present.
    def role_in(project)
      @roles ||= {}
      @roles.fetch(project.id) do
        @roles[project.id] = project.try(:current_role) ||
          Membership.where(project_id: project.id, user_id: user.id).pick(:role) ||
          role_through_organization(project)
      end
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
