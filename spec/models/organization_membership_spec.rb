require "rails_helper"

RSpec.describe OrganizationMembership do
  let(:owner) { create(:user) }
  let!(:organization) { create(:organization, owner: owner) }
  let(:owner_role) { described_class.find_by!(organization: organization, user: owner) }

  it { is_expected.to belong_to(:organization) }
  it { is_expected.to belong_to(:user) }
  it { is_expected.to define_enum_for(:role).with_values(member: "member", admin: "admin", owner: "owner").backed_by_column_of_type(:string) }

  it "allows a user in an organization once" do
    existing = create(:organization_membership, organization: organization)
    duplicate = build(:organization_membership, organization: organization, user: existing.user)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:user_id]).to include("is already a member of this organization")
  end

  describe "the last owner" do
    it "cannot be demoted" do
      expect(owner_role.update(role: "admin")).to be(false)
      expect(owner_role.errors[:role].first).to include("at least one owner")
    end

    it "cannot be removed" do
      expect(owner_role.destroy).to be(false)
      expect(owner_role.errors[:base].first).to include("last owner")
      expect(owner_role.reload).to be_persisted
    end

    it "can be once someone else is an owner too" do
      create(:organization_membership, :owner, organization: organization)

      expect(owner_role.update(role: "admin")).to be(true)
    end
  end

  it "goes along with the organization when it is deleted" do
    expect { organization.destroy! }.to change(described_class, :count).by(-1)
  end
end
