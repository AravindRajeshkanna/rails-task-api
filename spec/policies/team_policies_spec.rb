require "rails_helper"

# TeamPolicy, TeamMembershipPolicy and ProjectTeamPolicy: the organization's administrators manage teams
# and who is in them; any member of the organization can look; project admins manage a team's access.
RSpec.describe "Team policies" do
  let(:organization) { create(:organization) }
  let(:owner) { create(:organization_membership, :owner, organization: organization).user }
  let(:admin) { create(:organization_membership, :admin, organization: organization).user }
  let(:member) { create(:organization_membership, organization: organization).user }
  let(:stranger) { create(:user) }
  let!(:team) { create(:team, organization: organization) }
  let(:membership) { create(:team_membership, team: team, user: member) }

  describe TeamPolicy do
    it "lets owners and admins manage teams" do
      [ owner, admin ].each { |user| expect(described_class.new(user, team)).to permit_actions(:index, :show, :create, :update, :destroy) }
    end

    it "lets plain members look but not touch" do
      expect(described_class.new(member, team)).to permit_actions(:index, :show)
      expect(described_class.new(member, team)).to forbid_actions(:create, :update, :destroy)
    end

    it "gives strangers nothing" do
      expect(described_class.new(stranger, team)).to forbid_actions(:index, :show, :create, :update, :destroy)
    end

    it "scopes to the teams of the user's organizations" do
      create(:team)

      expect(described_class::Scope.new(member, Team).resolve).to contain_exactly(team)
      expect(described_class::Scope.new(stranger, Team).resolve).to be_empty
    end
  end

  describe TeamMembershipPolicy do
    it "lets owners and admins add and remove people" do
      [ owner, admin ].each { |user| expect(described_class.new(user, membership)).to permit_actions(:index, :create, :destroy) }
    end

    it "lets plain members see who is in a team, nothing more (not even leaving it themselves)" do
      expect(described_class.new(member, membership)).to permit_action(:index)
      expect(described_class.new(member, membership)).to forbid_actions(:create, :destroy)
    end

    it "gives strangers nothing" do
      expect(described_class.new(stranger, membership)).to forbid_actions(:index, :create, :destroy)
    end

    describe "a maintainer of the team" do
      let(:maintainer) { create(:team_membership, team: team, role: "maintainer").user }
      let(:plain) { create(:team_membership, team: team) }
      let(:fellow_maintainer) { create(:team_membership, team: team, role: "maintainer") }

      it "adds and removes the plain members of their own team" do
        expect(described_class.new(maintainer, plain)).to permit_actions(:index, :create, :destroy)
        expect(described_class.new(maintainer, build(:team_membership, team: team))).to permit_action(:create)
      end

      it "cannot make a maintainer, change a role, remove another maintainer, or remove themselves" do
        expect(described_class.new(maintainer, build(:team_membership, team: team, role: "maintainer"))).to forbid_action(:create)
        expect(described_class.new(maintainer, plain)).to forbid_action(:update)
        expect(described_class.new(maintainer, fellow_maintainer)).to forbid_actions(:update, :destroy)
        expect(described_class.new(maintainer, TeamMembership.find_by!(user: maintainer))).to forbid_actions(:update, :destroy)
      end

      it "has nothing to do with any other team" do
        elsewhere = create(:team_membership, team: create(:team, organization: organization))
        maintainer # of `team`

        expect(described_class.new(maintainer, elsewhere)).to forbid_actions(:create, :update, :destroy)
      end

      it "is nothing once they leave the organization, whatever the row still says" do
        membership = TeamMembership.find_by!(user: maintainer)
        OrganizationMembership.where(user: maintainer).delete_all

        expect(described_class.new(maintainer, plain)).to forbid_actions(:index, :create, :destroy)
        expect(membership).to be_maintainer
      end

      it "is not an administrator of the team itself, or of any project" do
        expect(TeamPolicy.new(maintainer, team)).to permit_actions(:index, :show)
        expect(TeamPolicy.new(maintainer, team)).to forbid_actions(:update, :destroy)
      end
    end

    it "scopes to the teams of the user's organizations" do
      create(:team_membership)
      membership

      expect(described_class::Scope.new(member, TeamMembership).resolve).to contain_exactly(membership)
    end
  end

  describe ProjectTeamPolicy do
    let(:project_owner) { create(:organization_membership, organization: organization).user }
    let!(:project) { create(:project, owner: project_owner, organization: organization) }
    let(:grant) { create(:project_team, project: project, team: team) }

    it "lets project admins grant, change and withdraw access" do
      expect(described_class.new(project_owner, grant)).to permit_actions(:index, :create, :update, :destroy)
      expect(described_class.new(admin, grant)).to permit_actions(:index, :create, :update, :destroy) # organization admin
    end

    it "lets project members see who has access, not change it" do
      create(:membership, project: project, user: member)

      expect(described_class.new(member, grant)).to permit_action(:index)
      expect(described_class.new(member, grant)).to forbid_actions(:create, :update, :destroy)
    end

    it "gives nothing to a member of the organization who is not in the project, or to strangers" do
      expect(described_class.new(member, grant)).to forbid_actions(:index, :create, :update, :destroy)
      expect(described_class.new(stranger, grant)).to forbid_actions(:index, :create, :update, :destroy)
    end

    it "freezes the access of an archived project" do
      project.update!(discarded_at: Time.current)

      expect(described_class.new(project_owner, grant)).to forbid_actions(:create, :update, :destroy)
    end
  end
end
