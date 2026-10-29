require "rails_helper"

RSpec.describe OrganizationMembershipPolicy do
  let(:owner) { create(:user) }
  let(:admin) { create(:user) }
  let(:member) { create(:user) }
  let(:stranger) { create(:user) }
  let!(:organization) { create(:organization, owner: owner) }
  let!(:admin_role) { create(:organization_membership, :admin, organization: organization, user: admin) }
  let!(:member_role) { create(:organization_membership, organization: organization, user: member) }
  let!(:owner_role) { OrganizationMembership.find_by!(organization: organization, user: owner) }

  def policy(user, membership) = described_class.new(user, membership)

  describe "changing roles" do
    it "is for owners only" do
      expect(policy(owner, member_role)).to permit_action(:update)
      expect(policy(admin, member_role)).to forbid_action(:update)
      expect(policy(admin, admin_role)).to forbid_action(:update) # no promoting yourself
      expect(policy(member, member_role)).to forbid_action(:update)
    end
  end

  describe "removing people" do
    it "lets owners remove anyone" do
      expect(policy(owner, admin_role)).to permit_action(:destroy)
      expect(policy(owner, member_role)).to permit_action(:destroy)
    end

    it "lets admins remove plain members but not admins or owners" do
      expect(policy(admin, member_role)).to permit_action(:destroy)
      expect(policy(admin, owner_role)).to forbid_action(:destroy)
    end

    it "lets anyone leave, and nobody remove someone else" do
      expect(policy(member, member_role)).to permit_action(:destroy)
      expect(policy(member, admin_role)).to forbid_action(:destroy)
      expect(policy(stranger, member_role)).to forbid_action(:destroy)
    end
  end

  it "lists members only to people in the organization" do
    expect(policy(member, organization.organization_memberships.build)).to permit_action(:index)
    expect(policy(stranger, organization.organization_memberships.build)).to forbid_action(:index)
  end
end
