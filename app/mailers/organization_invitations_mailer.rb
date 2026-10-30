class OrganizationInvitationsMailer < ApplicationMailer
  # The link carries a fresh token each time it is rendered, so a resend never depends on an old mail.
  def invite(invitation)
    @invitation = invitation
    @organization = invitation.organization
    @inviter = invitation.invited_by
    @accept_url = frontend_url("/invitations/accept?token=#{CGI.escape(invitation.generate_token_for(:acceptance))}")
    @expires_on = invitation.expires_at.to_date.to_fs(:long)
    mail subject: "You're invited to join #{@organization.name}", to: invitation.email_address
  end
end
