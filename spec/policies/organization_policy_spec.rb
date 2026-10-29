require "rails_helper"

RSpec.describe OrganizationPolicy do
  let(:owner) { create(:user) }
  let(:admin) { create(:user) }
  let(:member) { create(:user) }
  let(:stranger) { create(:user) }
  let!(:organization) { create(:organization, owner: owner) }

  before do
    create(:organization_membership, :admin, organization: organization, user: admin)
    create(:organization_membership, organization: organization, user: member)
  end

  it "lets every role read it and only owners and admins change it" do
    expect(described_class.new(member, organization)).to permit_actions(%i[show create_project]).and forbid_actions(%i[update destroy])
    expect(described_class.new(admin, organization)).to permit_actions(%i[show update create_project]).and forbid_action(:destroy)
    expect(described_class.new(owner, organization)).to permit_actions(%i[show update destroy create_project])
  end

  it "shows a stranger nothing" do
    expect(described_class.new(stranger, organization)).to forbid_actions(%i[show update destroy create_project])
  end

  it "scopes to the organizations the user is in, with their role" do
    other = create(:organization, owner: stranger)

    scope = described_class::Scope.new(member, Organization).resolve

    expect(scope).to contain_exactly(organization)
    expect(scope.first.current_role).to eq("member")
    expect(scope).not_to include(other)
  end
end
