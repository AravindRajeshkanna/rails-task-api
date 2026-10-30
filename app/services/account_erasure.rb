# Erases a person while keeping what they did for the people they did it with. The user row stays, as a tombstone
# ("Deleted user", an address that cannot receive mail, no password, no sign-ins), because tasks, comments and the audit
# trail point at it; everything that identifies or follows the person is deleted. docs/data-protection.md lists what goes and what stays.
#
# Refused (nothing changes) while the person owns a project that is not archived, or is the last owner of an organization:
# those would be left without anyone responsible. Calling it again on an erased user does nothing.
class AccountErasure
  class Blocked < StandardError
    attr_reader :code

    def initialize(code, message)
      super(message)
      @code = code
    end
  end

  TOMBSTONE_NAME = "Deleted user".freeze

  def self.call(user) = new(user).call

  def initialize(user)
    @user = user
  end

  def call
    return user if user.erased?

    refuse_while_responsible!
    address = user.email_address

    User.transaction do
      leave_projects_and_organizations
      delete_personal_data
      unassign_tasks
      forget_invitations_to(address)
      user.avatar.purge_later
      tombstone
    end

    Rails.event.notify("user.erased", user_id: user.id)
    user
  end

  private
    attr_reader :user

    def leave_projects_and_organizations
      user.memberships.where.not(project_id: Project.where(owner_id: user.id).select(:id)).destroy_all # an archived project of theirs keeps its owner row
      user.organization_memberships.destroy_all # which also takes them out of the organization's teams
    end

    def delete_personal_data
      user.sessions.delete_all
      user.notification_setting&.delete
      user.notification_mutes.delete_all
      Notification.where(user_id: user.id).delete_all
      IdempotencyKey.where(user_id: user.id).delete_all
    end

    def refuse_while_responsible!
      projects = Project.kept.where(owner_id: user.id).count
      raise Blocked.new("owns_projects", "You own #{projects} #{'project'.pluralize(projects)}. Archive them first: a project needs an owner.") if projects.positive?

      organization = user.organization_memberships.owner.includes(:organization).find { |membership| sole_owner?(membership) }&.organization
      raise Blocked.new("last_organization_owner", "You are the last owner of #{organization.name}. Make someone else an owner, or delete it, first.") if organization
    end

    def sole_owner?(membership)
      !OrganizationMembership.owner.where(organization_id: membership.organization_id).where.not(id: membership.id).exists?
    end

    # The work stays; it just has nobody on it. updated_at moves so that cached copies of the task are not served with the old assignee.
    def unassign_tasks
      user.assigned_tasks.update_all(assignee_id: nil, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations -- the trail would record the person's own erasure N times
    end

    # An invitation names an address, with or without an account behind it; the ones addressed to this person go.
    def forget_invitations_to(address) = OrganizationInvitation.forget!(OrganizationInvitation.where(email_address: address))

    def tombstone
      user.update_columns( # rubocop:disable Rails/SkipsModelValidations -- the tombstone is deliberately not a valid user (no password, no way in)
        name: TOMBSTONE_NAME, email_address: "erased-#{user.id}@erased.invalid", password_digest: nil, auth_subject: nil,
        erased_at: Time.current, updated_at: Time.current
      )
    end
end
