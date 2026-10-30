module Organizations
  # Turns an invitation into a membership, for the signed-in +user+ who holds the mailed +token+.
  #
  # Anything wrong with the invitation (unknown, expired, already used, revoked, addressed to
  # someone else) is the same ActiveRecord::RecordNotFound, so the endpoint cannot be used to find out
  # which invitations exist or who they are for.
  class AcceptInvitation < ApplicationCommand
    def initialize(user:, token:)
      super()
      @user = user
      @token = token.to_s
    end

    def call
      invitation = OrganizationInvitation.find_by_token_for(:acceptance, @token) or raise ActiveRecord::RecordNotFound

      invitation.with_lock do
        raise ActiveRecord::RecordNotFound unless invitation.pending? && invitation.email_address == @user.email_address

        membership = invitation.organization.organization_memberships.create!(user: @user, role: invitation.role)
        invitation.update!(accepted_at: Time.current)
        membership
      end
    end
  end
end
