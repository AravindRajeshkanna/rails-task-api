require "rails_helper"

RSpec.describe Team do
  it { is_expected.to belong_to(:organization) }
  it { is_expected.to validate_presence_of(:name) }
  it { is_expected.to validate_length_of(:name).is_at_most(100) }
  it { is_expected.to have_many(:team_memberships).dependent(:destroy) }
  it { is_expected.to have_many(:project_teams).dependent(:destroy) }

  it "squishes the name" do
    expect(create(:team, name: "  Back   End ").name).to eq("Back End")
  end

  it "has a name that is unique within the organization, ignoring case, but not across organizations" do
    organization = create(:organization)
    create(:team, organization: organization, name: "Design")

    expect(build(:team, organization: organization, name: "design")).not_to be_valid
    expect(build(:team, name: "Design")).to be_valid
    expect { build(:team, organization: organization, name: "DESIGN").save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "takes its members' access and its memberships with it when deleted" do
    grant = create(:project_team)
    create(:team_membership, team: grant.team)

    expect { grant.team.destroy! }.to change(TeamMembership, :count).by(-1).and change(ProjectTeam, :count).by(-1)
  end

  describe "nesting" do
    let(:organization) { create(:organization) }
    let!(:parent) { create(:team, organization: organization) }

    it "lets a team have a parent in the same organization" do
      child = create(:team, organization: organization, parent: parent)

      expect(child.parent).to eq(parent)
      expect(parent.sub_teams).to contain_exactly(child)
    end

    it "gives the same answer for a parent that is another organization's as for one that does not exist" do
      elsewhere = create(:team)
      foreign = build(:team, organization: organization, parent_id: elsewhere.id)
      missing = build(:team, organization: organization, parent_id: 0)

      expect([ foreign, missing ]).to all(be_invalid)
      expect(foreign.errors[:parent]).to eq(missing.errors[:parent]).and eq([ "must be another team of this organization" ])
    end

    it "nests one level: a sub-team cannot be a parent, and a parent cannot become a sub-team" do
      child = create(:team, organization: organization, parent: parent)

      grandchild = build(:team, organization: organization, parent: child)
      expect(grandchild).to be_invalid
      expect(grandchild.errors[:parent]).to eq([ "cannot be a sub-team: teams nest one level" ])

      other = create(:team, organization: organization)
      parent.parent = other
      expect(parent).to be_invalid
      expect(parent.errors[:parent].sole).to include("has sub-teams")
    end

    it "is not its own parent" do
      parent.parent = parent

      expect(parent).to be_invalid
    end

    it "cannot be deleted while it has sub-teams, and its sub-teams cannot lose it by accident" do
      create(:team, organization: organization, parent: parent)

      expect { parent.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
      expect(parent.errors[:base].sole).to include("sub teams")
      expect(described_class.exists?(parent.id)).to be(true)
    end

    it "cannot be deleted with sub-teams even bypassing the model: the database refuses" do
      create(:team, organization: organization, parent: parent)

      expect { described_class.transaction(requires_new: true) { parent.delete } }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    describe ".granting_to and .with_sub_teams" do
      it "name the teams whose grants a person has, and the teams a grant reaches" do
        child = create(:team, organization: organization, parent: parent)
        sibling = create(:team, organization: organization, parent: parent)
        person = create(:team_membership, team: child).user

        expect(described_class.granting_to(person.id)).to contain_exactly(child, parent)
        expect(described_class.with_sub_teams([ parent.id ])).to contain_exactly(parent, child, sibling)
        expect(described_class.with_sub_teams([ child.id ])).to contain_exactly(child)
      end
    end
  end
end

RSpec.describe TeamMembership do
  it { is_expected.to belong_to(:team) }
  it { is_expected.to belong_to(:user) }

  it "only takes members of the team's organization" do
    stranger = described_class.new(team: create(:team), user: create(:user))

    expect(stranger).not_to be_valid
    expect(stranger.errors[:user]).to include("must be a member of the team's organization")
  end

  it "puts someone in a team once" do
    membership = create(:team_membership)

    duplicate = described_class.new(team: membership.team, user: membership.user)
    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:user_id]).to include("is already in this team")
  end

  it "ends when the person leaves the organization, by any route" do
    membership = create(:team_membership)
    other_team = create(:team_membership, user: membership.user, team: create(:team, organization: membership.team.organization))
    elsewhere = create(:team_membership, user: membership.user)

    OrganizationMembership.find_by!(organization: membership.team.organization, user: membership.user).destroy!

    expect(TeamMembership.where(id: [ membership.id, other_team.id ])).to be_empty
    expect(TeamMembership.exists?(elsewhere.id)).to be(true) # a team in another organization is untouched
  end
end

RSpec.describe ProjectTeam do
  it { is_expected.to belong_to(:project) }
  it { is_expected.to belong_to(:team) }
  it { is_expected.to define_enum_for(:role).with_values(member: "member", admin: "admin").backed_by_column_of_type(:string) }

  it "only takes a team of the project's own organization" do
    organization = create(:organization)
    project = create(:project, organization: organization, owner: create(:organization_membership, organization: organization).user)

    foreign = described_class.new(project: project, team: create(:team))
    personal = described_class.new(project: create(:project), team: create(:team))

    expect(foreign).not_to be_valid
    expect(foreign.errors[:team]).to include("must belong to the project's organization")
    expect(personal).not_to be_valid
  end

  it "grants a team a project once" do
    grant = create(:project_team)

    duplicate = described_class.new(project: grant.project, team: grant.team)
    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:team_id]).to include("already has access to this project")
  end
end
