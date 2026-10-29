module Organizations
  # Takes someone out of an organization, and with them their access to the organization's
  # projects: the tenant boundary would be meaningless if a former member kept project access.
  #
  # Refused while they still own one of its projects, because a project must keep an owner who
  # belongs to its organization; transfer or delete those first.
  class RemoveMember < ApplicationCommand
    def initialize(membership:)
      super()
      @membership = membership
    end

    def call
      organization = @membership.organization
      user = @membership.user

      OrganizationMembership.transaction do
        if organization.projects.exists?(owner_id: user.id)
          @membership.errors.add(:base, "#{user.name} still owns projects in this organization; transfer or delete them first")
          raise ActiveRecord::RecordInvalid, @membership
        end

        Membership.where(user_id: user.id, project_id: organization.projects.select(:id)).destroy_all
        @membership.destroy!
      end
    rescue ActiveRecord::RecordNotDestroyed
      raise ActiveRecord::RecordInvalid, @membership
    end
  end
end
