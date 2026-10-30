require "rails_helper"

RSpec.describe OrganizationInvitationsMailer do
  let(:organization) { create(:organization, name: "Acme") }
  let(:inviter) { create(:user, name: "Ada") }
  let(:invitation) { create(:organization_invitation, organization: organization, invited_by: inviter, email_address: "new@example.com", role: "admin") }

  subject(:mail) { described_class.invite(invitation) }

  it "goes to the invited address and says who invited them to what" do
    expect(mail).to have_attributes(to: [ "new@example.com" ], subject: "You're invited to join Acme")
    expect(mail.body.to_s).to include("Ada invited you", "\"Acme\"", "an admin", "new@example.com")
  end

  it "links to the front end with a token that redeems this invitation" do
    link = mail.body.to_s[%r{#{Regexp.escape(Rails.configuration.x.frontend_url)}/invitations/accept\?token=\S+}]
    token = CGI.unescape(link.split("token=").last)

    expect(OrganizationInvitation.find_by_token_for(:acceptance, token)).to eq(invitation)
  end

  it "still reads well when the inviter's account is gone" do
    invitation.update!(invited_by: nil)

    expect(mail.body.to_s).to include("An administrator invited you")
  end

  it "carries a fresh token each time, so a resend never depends on an old mail" do
    first = mail.body.to_s[/token=\S+/]
    travel(2.days) { expect(described_class.invite(invitation).body.to_s[/token=\S+/]).not_to eq(first) }
  end
end
