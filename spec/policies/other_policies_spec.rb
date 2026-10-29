require "rails_helper"

RSpec.describe "Child resource policies" do
  let(:project) { create(:project) }
  let(:admin) { project.owner }
  let(:member) { create(:membership, project:).user }
  let(:outsider) { create(:user) }
  let(:task) { create(:task, project:) }

  describe CommentPolicy do
    let(:comment) { create(:comment, task:, user: member) }

    it "lets the author edit and delete, admins delete, others nothing" do
      expect(described_class.new(member, comment)).to permit_actions(%i[index create update destroy])
      expect(described_class.new(admin, comment)).to permit_actions(%i[index create destroy])
      expect(described_class.new(admin, comment)).to forbid_action(:update)
      expect(described_class.new(create(:membership, project:).user, comment)).to forbid_actions(%i[update destroy])
      expect(described_class.new(outsider, comment)).to forbid_actions(%i[index create update destroy])
    end
  end

  describe TagPolicy do
    let(:tag) { create(:tag, project:) }

    it "lets members create but only admins delete" do
      expect(described_class.new(member, tag)).to permit_actions(%i[index create])
      expect(described_class.new(member, tag)).to forbid_action(:destroy)
      expect(described_class.new(admin, tag)).to permit_actions(%i[index create destroy])
      expect(described_class.new(outsider, tag)).to forbid_actions(%i[index create destroy])
    end
  end

  describe MembershipPolicy do
    let(:membership) { project.memberships.find_by!(user: member) }

    it "lets admins manage, members leave, and outsiders nothing" do
      expect(described_class.new(admin, membership)).to permit_actions(%i[index create update destroy])
      expect(described_class.new(member, membership)).to permit_actions(%i[index destroy])
      expect(described_class.new(member, membership)).to forbid_actions(%i[create update])
      expect(described_class.new(outsider, membership)).to forbid_actions(%i[index create update destroy])
    end
  end

  describe WebhookPolicy do
    let(:webhook) { create(:webhook, project:) }

    it "is admin-only" do
      expect(described_class.new(admin, webhook)).to permit_actions(%i[index show create update destroy])
      expect(described_class.new(member, webhook)).to forbid_actions(%i[index show create update destroy])
      expect(described_class.new(outsider, webhook)).to forbid_actions(%i[index show create update destroy])
    end

    it "scopes to projects where the user is an admin" do
      webhook
      other = create(:webhook, project: create(:membership, user: member).project)

      resolved = described_class::Scope.new(member, Webhook).resolve
      expect(resolved).to be_empty

      expect(described_class::Scope.new(admin, Webhook).resolve).to contain_exactly(webhook)
      expect(other).to be_persisted
    end
  end
end
