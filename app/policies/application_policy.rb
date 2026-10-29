# Default-deny. Every policy answers questions about a user's role *within a
# project*: members can work with tasks, admins manage the project, and only the
# owner can delete it.
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
      # Ids of the non-discarded projects the user belongs to (optionally only as +role+).
      # Child resources are scoped through this, so everything inside a discarded project
      # is a 404 until the project is restored.
      def member_project_ids(role: nil)
        memberships = Membership.joins(:project).merge(Project.kept).where(user_id: user.id)
        memberships = memberships.where(role: role) if role
        memberships.select(:project_id)
      end
  end

  private
    # Role of the current user in +project+ ("admin", "member" or nil). Reuses the
    # +current_role+ column selected by ProjectPolicy::Scope when it is present.
    def role_in(project)
      @roles ||= {}
      @roles.fetch(project.id) do
        @roles[project.id] = project.try(:current_role) ||
          Membership.where(project_id: project.id, user_id: user.id).pick(:role)
      end
    end

    def member_of?(project) = role_in(project).present?
    def admin_of?(project) = role_in(project) == "admin"
end
