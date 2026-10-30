module Organizations
  # Invites an email address to an organization and mails the link.
  #
  # Inviting an address that already has an open invitation refreshes it (new role, new expiry) and
  # mails the link again, so "resend" is the same call. Whether the address belongs to a registered
  # user plays no part: the answer is the same, and the person is told by email either way.
  class Invite < ApplicationCommand
    def initialize(organization:, email_address:, role:, invited_by:)
      super()
      @organization = organization
      @email_address = email_address
      @role = role
      @invited_by = invited_by
    end

    def call
      invitation = send_invitation
      OrganizationInvitationsMailer.invite(invitation).deliver_later
      invitation
    end

    private
      def send_invitation
        attempts = 0
        begin
          invitation = @organization.organization_invitations.outstanding.find_or_initialize_by(email_address: normalized_email)
          invitation.update!(role: @role, invited_by: @invited_by, expires_at: OrganizationInvitation::VALID_FOR.from_now)
          invitation
        rescue ActiveRecord::RecordNotUnique
          # Two people invited the same address at once; the second sees the first one's row and refreshes it.
          retry if (attempts += 1) < 2
          raise
        end
      end

      def normalized_email = OrganizationInvitation.normalize_value_for(:email_address, @email_address.to_s)
  end
end
