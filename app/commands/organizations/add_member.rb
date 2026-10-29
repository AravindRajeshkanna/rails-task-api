module Organizations
  # Adds an existing user, found by email address, to an organization.
  class AddMember < ApplicationCommand
    def initialize(organization:, email_address:, role:)
      super()
      @organization = organization
      @email_address = email_address.to_s.strip.downcase
      @role = role
    end

    def call
      user = User.find_by!(email_address: @email_address)
      @organization.organization_memberships.create!(user: user, role: @role)
    end
  end
end
