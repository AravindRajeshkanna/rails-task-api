require "rails_helper"

RSpec.describe OrganizationInvitation do
  it { is_expected.to belong_to(:organization) }
  it { is_expected.to validate_presence_of(:email_address) }
  it { is_expected.to define_enum_for(:role).with_values(member: "member", admin: "admin", owner: "owner").backed_by_column_of_type(:string) }

  it "normalizes the address" do
    expect(build(:organization_invitation, email_address: "  New.Person@Example.COM ").email_address).to eq("new.person@example.com")
  end

  it "rejects a malformed address" do
    expect(build(:organization_invitation, email_address: "not-an-email")).not_to be_valid
  end

  it "rejects an address that already belongs to a member" do
    member = create(:user)
    organization = create(:organization)
    create(:organization_membership, organization: organization, user: member)

    invitation = build(:organization_invitation, organization: organization, email_address: member.email_address.upcase)

    expect(invitation).not_to be_valid
    expect(invitation.errors[:email_address]).to include("already belongs to a member of this organization")
  end

  it "allows only one open invitation per address and organization, but any number once they are closed" do
    open = create(:organization_invitation)

    expect { create(:organization_invitation, organization: open.organization, email_address: open.email_address) }
      .to raise_error(ActiveRecord::RecordNotUnique)

    open.revoke!
    expect { create(:organization_invitation, organization: open.organization, email_address: open.email_address) }.not_to raise_error
  end

  describe "#status" do
    it "tells the four states apart" do
      expect(build(:organization_invitation).status).to eq("pending")
      expect(build(:organization_invitation, :expired).status).to eq("expired")
      expect(build(:organization_invitation, :accepted).status).to eq("accepted")
      expect(build(:organization_invitation, :revoked).status).to eq("revoked")
    end
  end

  describe "the acceptance token" do
    let(:invitation) { create(:organization_invitation) }

    it "finds the invitation" do
      expect(described_class.find_by_token_for(:acceptance, invitation.generate_token_for(:acceptance))).to eq(invitation)
    end

    it "stops working once the invitation is accepted or revoked" do
      accepted = create(:organization_invitation)
      revoked = create(:organization_invitation)
      accepted_token = accepted.generate_token_for(:acceptance)
      revoked_token = revoked.generate_token_for(:acceptance)

      accepted.update!(accepted_at: Time.current)
      revoked.revoke!

      expect(described_class.find_by_token_for(:acceptance, accepted_token)).to be_nil
      expect(described_class.find_by_token_for(:acceptance, revoked_token)).to be_nil
    end

    it "expires" do
      token = invitation.generate_token_for(:acceptance)

      travel_to(OrganizationInvitation::VALID_FOR.from_now + 1.minute) do
        expect(described_class.find_by_token_for(:acceptance, token)).to be_nil
      end
    end

    it "is not valid for another purpose, and garbage is nil" do
      expect(described_class.find_by_token_for(:acceptance, "garbage")).to be_nil
      expect(described_class.find_by_token_for(:acceptance, User.new(id: 1).generate_token_for(:password_reset))).to be_nil
    end
  end
end
