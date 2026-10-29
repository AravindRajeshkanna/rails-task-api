require "rails_helper"

RSpec.describe Membership do
  let(:project) { create(:project) }

  describe "validations" do
    subject { build(:membership, project:) }

    it { is_expected.to belong_to(:project) }
    it { is_expected.to belong_to(:user) }
    it { is_expected.to validate_uniqueness_of(:user_id).scoped_to(:project_id).with_message("is already a member of this project") }
    it { is_expected.to define_enum_for(:role).with_values(member: "member", admin: "admin").backed_by_column_of_type(:string) }
  end

  describe "protecting the owner" do
    let(:owner_membership) { project.memberships.find_by!(user: project.owner) }

    it "refuses to demote the owner" do
      expect(owner_membership.update(role: :member)).to be(false)
      expect(owner_membership.errors[:role]).to be_present
    end

    it "refuses to remove the owner" do
      expect(owner_membership.destroy).to be(false)
      expect(owner_membership.errors[:base]).to include("The project owner cannot be removed")
    end

    it "still removes everything when the project itself is destroyed" do
      project # create it before measuring
      expect { project.destroy! }.to change(Membership, :count).by(-1)
    end
  end

  it "lets non-owners be demoted and removed" do
    membership = create(:membership, :admin, project:)

    expect(membership.update(role: :member)).to be(true)
    expect { membership.destroy! }.to change(Membership, :count).by(-1)
  end
end
