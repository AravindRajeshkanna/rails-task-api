require "rails_helper"

# Access through a team, added up with the other routes in. Every example checks both ways the
# application resolves a role -- the SQL in ProjectPolicy::Scope (lists, child resources) and the
# per-record lookup (a project loaded some other way) -- because they must never disagree.
RSpec.describe ProjectPolicy do
  let(:organization) { create(:organization) }
  let(:owner) { create(:organization_membership, organization: organization).user }
  let(:person) { create(:user) }
  let!(:project) { create(:project, owner: owner, organization: organization) }
  let(:team) { create(:team, organization: organization) }

  def role_via_scope(user)
    described_class::Scope.new(user, Project).resolve.find_by(id: project.id)&.current_role
  end

  def role_via_record(user)
    policy = described_class.new(user, Project.find(project.id)) # no current_role column on this one
    return "admin" if policy.update?

    policy.show? ? "member" : nil
  end

  def expect_role(user, role)
    expect(role_via_scope(user)).to eq(role), "through the scope"
    expect(role_via_record(user)).to eq(role), "through the record"
  end

  before { create(:team_membership, team: team, user: person) }

  it "gives nothing until the team is granted the project" do
    expect_role(person, nil)
  end

  it "gives a team member the role the team was granted" do
    grant = create(:project_team, project: project, team: team, role: "member")
    expect_role(person, "member")

    grant.update!(role: "admin")
    expect_role(person, "admin")
  end

  it "takes the highest role across routes: a plain team grant never lowers a direct admin, an admin grant raises a direct member" do
    create(:project_team, project: project, team: team, role: "member")
    create(:membership, project: project, user: person, role: "member")
    expect_role(person, "member")

    ProjectTeam.find_by!(project: project, team: team).update!(role: "admin")
    expect_role(person, "admin")

    ProjectTeam.find_by!(project: project, team: team).update!(role: "member")
    Membership.find_by!(project: project, user: person).update!(role: "admin")
    expect_role(person, "admin")
  end

  it "takes the highest role across several teams" do
    other = create(:team, organization: organization)
    create(:team_membership, team: other, user: person)
    create(:project_team, project: project, team: team, role: "member")
    create(:project_team, project: project, team: other, role: "admin")

    expect_role(person, "admin")
  end

  it "lets an organization admin who is a plain project member administer (the two lookups agree)" do
    OrganizationMembership.find_by!(organization: organization, user: person).update!(role: "admin")
    create(:membership, project: project, user: person, role: "member")

    expect_role(person, "admin")
  end

  it "gives nothing to someone who left the team, or whose team lost the grant" do
    grant = create(:project_team, project: project, team: team)
    expect_role(person, "member")

    TeamMembership.find_by!(team: team, user: person).destroy!
    expect_role(person, nil)

    create(:team_membership, team: team, user: person)
    grant.destroy!
    expect_role(person, nil)
  end

  it "does not follow a team into a project it was not granted, or an archived one" do
    other_project = create(:project, owner: owner, organization: organization)
    create(:project_team, project: project, team: team)

    expect(described_class::Scope.new(person, Project).resolve.pluck(:id)).to eq([ project.id ])
    expect(described_class::Scope.new(person, Project).resolve.pluck(:id)).not_to include(other_project.id)

    project.update!(discarded_at: Time.current)
    expect(described_class::Scope.new(person, Project).resolve.kept).to be_empty
    expect(TaskPolicy::Scope.new(person, Task).resolve).to be_empty
  end

  it "reaches the child resources through the same ids" do
    create(:project_team, project: project, team: team)
    task = create(:task, project: project, creator: owner)

    expect(TaskPolicy::Scope.new(person, Task).resolve).to contain_exactly(task)
    expect(WebhookPolicy::Scope.new(person, Webhook).resolve).to be_empty # webhooks need admin

    ProjectTeam.find_by!(project: project, team: team).update!(role: "admin")
    webhook = create(:webhook, project: project)
    expect(WebhookPolicy::Scope.new(person, Webhook).resolve).to contain_exactly(webhook)
  end

  it "lists the project once, whichever way the person has access" do
    create(:project_team, project: project, team: team, role: "admin")
    create(:membership, project: project, user: person)
    OrganizationMembership.find_by!(organization: organization, user: person).update!(role: "admin")

    expect(described_class::Scope.new(person, Project).resolve.where(id: project.id).to_a.size).to eq(1)
  end

  describe "nested teams" do
    let(:parent) { create(:team, organization: organization, name: "Engineering") }
    let(:child) { create(:team, organization: organization, name: "Backend", parent: parent) }
    let(:sibling) { create(:team, organization: organization, name: "Frontend", parent: parent) }
    let(:in_child) { create(:team_membership, team: child).user }
    let(:in_parent) { create(:team_membership, team: parent).user }
    let(:in_sibling) { create(:team_membership, team: sibling).user }

    it "gives the members of a sub-team what its parent was granted, without their being in the parent" do
      create(:project_team, project: project, team: parent, role: "member")

      expect_role(in_child, "member")
      expect_role(in_sibling, "member")
      expect_role(in_parent, "member")
    end

    it "does not run the other way: a grant to a sub-team reaches only that sub-team" do
      create(:project_team, project: project, team: child, role: "member")

      expect_role(in_child, "member")
      expect_role(in_parent, nil)
      expect_role(in_sibling, nil)
    end

    it "takes the highest role across the sub-team's own grant and its parent's" do
      create(:project_team, project: project, team: child, role: "member")
      create(:project_team, project: project, team: parent, role: "admin")
      expect_role(in_child, "admin")

      ProjectTeam.find_by!(project: project, team: parent).update!(role: "member")
      ProjectTeam.find_by!(project: project, team: child).update!(role: "admin")
      expect_role(in_child, "admin")
      expect_role(in_sibling, "member")
    end

    it "ends when the team stops being a sub-team, or the person leaves it, or the grant goes" do
      grant = create(:project_team, project: project, team: parent)
      expect_role(in_child, "member")

      child.update!(parent: nil)
      expect_role(in_child, nil)

      child.update!(parent: parent)
      expect_role(in_child, "member")
      TeamMembership.find_by!(team: child, user: in_child).destroy!
      expect_role(in_child, nil)

      create(:team_membership, team: child, user: in_child)
      grant.destroy!
      expect_role(in_child, nil)
    end

    it "lists the project once, whichever of the person's routes reach it" do
      create(:project_team, project: project, team: parent, role: "member")
      create(:project_team, project: project, team: child, role: "admin")
      create(:team_membership, team: parent, user: in_child) # in both

      rows = described_class::Scope.new(in_child, Project).resolve.where(id: project.id).to_a
      expect(rows.size).to eq(1)
      expect(rows.sole.current_role).to eq("admin")
    end

    it "makes the members of sub-teams people who can be given work, and not the members of a parent whose sub-team was granted" do
      create(:project_team, project: project, team: parent)
      expect(project.participants).to include(in_child, in_sibling, in_parent)

      ProjectTeam.find_by!(project: project, team: parent).destroy!
      create(:project_team, project: project, team: child)
      expect(project.participants).to include(in_child)
      expect(project.participants).not_to include(in_parent, in_sibling)
    end

    it "reaches the child resources of the project through the sub-team" do
      create(:project_team, project: project, team: parent)
      task = create(:task, project: project, creator: owner)

      expect(TaskPolicy::Scope.new(in_child, Task).resolve).to contain_exactly(task)
      expect(NotificationPolicy::Scope.new(in_child, Notification).resolve).to be_empty
    end
  end
end
