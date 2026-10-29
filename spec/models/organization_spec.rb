require "rails_helper"

RSpec.describe Organization do
  it { is_expected.to validate_presence_of(:name) }
  it { is_expected.to validate_length_of(:name).is_at_most(100) }
  it { is_expected.to have_many(:organization_memberships).dependent(:destroy) }
  it { is_expected.to have_many(:projects).dependent(:restrict_with_error) }

  it "squishes the name" do
    expect(create(:organization, name: "  Acme    Corp ").name).to eq("Acme Corp")
  end

  it "cannot be deleted while it has projects, even deleted ones" do
    organization = create(:organization)
    owner = create(:user)
    create(:organization_membership, organization: organization, user: owner)
    create(:project, :discarded, owner: owner, organization: organization)

    expect(organization.destroy).to be(false)
    expect(organization.errors[:base]).to be_present
    expect(organization.reload.organization_memberships.count).to eq(1) # the refused delete rolled back entirely
  end
end
