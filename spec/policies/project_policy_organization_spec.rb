require "rails_helper"

# What belonging to an organization means for the projects inside it.
RSpec.describe "Project access through an organization" do
  let(:org_owner) { create(:user) }
  let(:org_admin) { create(:user) }
  let(:org_member) { create(:user) }
  let(:stranger) { create(:user) }
  let(:creator) { create(:user) }

  let!(:organization) { create(:organization, owner: org_owner) }
  let!(:creator_role) { create(:organization_membership, organization: organization, user: creator) } # a project's owner belongs to its organization
  let!(:project) { create(:project, owner: creator, organization: organization) }
  let!(:personal_project) { create(:project, owner: creator) }
  let!(:other_org_project) { create(:project, owner: stranger, organization: create(:organization, owner: stranger)) }

  before do
    create(:organization_membership, :admin, organization: organization, user: org_admin)
    create(:organization_membership, organization: organization, user: org_member)
  end

  # index? and create? are true for everyone (they are about the collection, not a record).
  let(:record_actions) { %i[show update destroy restore audit analytics manage_webhooks] }

  def policy(user, record = project) = ProjectPolicy.new(user, record)
  def visible_to(user) = ProjectPolicy::Scope.new(user, Project).resolve.kept.to_a

  describe "organization owners and admins" do
    it "administer the organization's projects without being members of them" do
      [ org_owner, org_admin ].each do |user|
        expect(Membership.where(project: project, user: user)).not_to exist
        expect(policy(user)).to permit_actions(%i[show update audit analytics manage_webhooks])
      end
    end

    it "see those projects in their scope, with the admin role" do
      [ org_owner, org_admin ].each do |user|
        expect(visible_to(user)).to contain_exactly(project)
        expect(ProjectPolicy::Scope.new(user, Project).resolve.find(project.id).current_role).to eq("admin")
      end
    end

    it "see nothing of personal projects or other organizations' projects" do
      [ org_owner, org_admin ].each do |user|
        expect(policy(user, personal_project)).to forbid_actions(record_actions)
        expect(policy(user, other_org_project)).to forbid_actions(record_actions)
        expect(visible_to(user)).not_to include(personal_project, other_org_project)
      end
    end

    it "reach the project's tasks and comments through the same scopes" do
      task = create(:task, project: project, creator: creator)
      comment = create(:comment, task: task, user: creator)

      [ org_owner, org_admin ].each do |user|
        expect(TaskPolicy::Scope.new(user, Task).resolve).to include(task)
        expect(CommentPolicy::Scope.new(user, Comment).resolve).to include(comment)
        expect(WebhookPolicy::Scope.new(user, Webhook).resolve).to include(create(:webhook, project: project))
        expect(TaskPolicy.new(user, task)).to permit_actions(%i[show update destroy])
      end
    end

    it "lose it as soon as they lose the role" do
      OrganizationMembership.find_by!(organization: organization, user: org_admin).update!(role: "member")

      expect(policy(org_admin)).to forbid_actions(record_actions)
      expect(visible_to(org_admin)).to be_empty
    end

    it "see a project only once, even if they are also a member of it" do
      create(:membership, project: project, user: org_admin)

      expect(visible_to(org_admin)).to eq([ project ])
    end

    it "do not see a deleted project" do
      project.discard

      expect(visible_to(org_admin)).to be_empty
      expect(policy(org_admin)).not_to permit_action(:show)
    end
  end

  describe "plain organization members" do
    it "get no access to projects they were not added to" do
      expect(policy(org_member)).to forbid_actions(record_actions)
      expect(visible_to(org_member)).to be_empty
    end

    it "work in a project once added to it, as in any project" do
      create(:membership, project: project, user: org_member)

      expect(policy(org_member)).to permit_action(:show).and forbid_action(:update)
    end
  end

  describe "deleting and restoring" do
    it "lets the project's owner and the organization's owners do it, but not its admins" do
      expect(policy(creator)).to permit_action(:destroy)
      expect(policy(org_owner)).to permit_action(:destroy)
      expect(policy(org_admin)).to forbid_action(:destroy)

      project.discard
      expect(policy(org_owner)).to permit_action(:restore)
      expect(policy(org_admin)).to forbid_action(:restore)
    end
  end

  describe "people outside the organization" do
    it "get nothing" do
      expect(policy(stranger)).to forbid_actions(record_actions)
      expect(visible_to(stranger)).to contain_exactly(other_org_project)
    end
  end
end
