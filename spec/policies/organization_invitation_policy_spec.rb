require "rails_helper"

RSpec.describe OrganizationInvitationPolicy do
  let(:owner) { create(:user) }
  let(:admin) { create(:user) }
  let(:member) { create(:user) }
  let(:stranger) { create(:user) }
  let!(:organization) { create(:organization, owner: owner) }

  before do
    create(:organization_membership, :admin, organization: organization, user: admin)
    create(:organization_membership, organization: organization, user: member)
  end

  def policy(user, invitation) = described_class.new(user, invitation)
  def offering(role) = build(:organization_invitation, organization: organization, role: role)

  it "lets owners offer any role" do
    %w[member admin owner].each { |role| expect(policy(owner, offering(role))).to permit_action(:create) }
  end

  it "lets admins offer plain membership only" do
    expect(policy(admin, offering("member"))).to permit_action(:create)
    expect(policy(admin, offering("admin"))).to forbid_action(:create)
    expect(policy(admin, offering("owner"))).to forbid_action(:create)
  end

  it "gives plain members and strangers nothing, not even the list (it holds email addresses)" do
    [ member, stranger ].each do |user|
      expect(policy(user, offering("member"))).to forbid_actions(:index, :create, :destroy)
    end
  end

  it "applies the same limits to withdrawing an invitation" do
    admins_offer = create(:organization_invitation, organization: organization, role: "admin")

    expect(policy(owner, admins_offer)).to permit_action(:destroy)
    expect(policy(admin, admins_offer)).to forbid_action(:destroy)
  end

  it "lets owners and admins list invitations" do
    expect(policy(owner, offering("member"))).to permit_action(:index)
    expect(policy(admin, offering("member"))).to permit_action(:index)
  end

  describe "Scope" do
    it "shows invitations only to the administrators of their organization" do
      invitation = create(:organization_invitation, organization: organization)
      create(:organization_invitation)

      scope = ->(user) { described_class::Scope.new(user, OrganizationInvitation).resolve }
      expect(scope.call(owner)).to contain_exactly(invitation)
      expect(scope.call(admin)).to contain_exactly(invitation)
      expect(scope.call(member)).to be_empty
      expect(scope.call(stranger)).to be_empty
    end
  end
end
