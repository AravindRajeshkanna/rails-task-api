module Organizations
  # Creates an organization and makes +user+ its first owner, together or not at all.
  class Create < ApplicationCommand
    def initialize(user:, attributes:)
      super()
      @user = user
      @attributes = attributes
    end

    def call
      Organization.transaction do
        organization = Organization.create!(@attributes)
        organization.organization_memberships.create!(user: @user, role: :owner)
        organization
      end
    end
  end
end
