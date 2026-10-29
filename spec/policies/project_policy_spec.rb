require "rails_helper"

RSpec.describe ProjectPolicy do
  subject(:policy) { described_class.new(user, project) }

  let(:project) { create(:project) }

  context "as the owner" do
    let(:user) { project.owner }

    it { is_expected.to permit_actions(%i[index create show update destroy audit manage_webhooks]) }
    it { is_expected.to forbid_action(:restore) } # only for discarded projects

    it "may restore once discarded" do
      project.discard

      expect(policy).to permit_action(:restore)
      expect(policy).to forbid_actions(%i[show update destroy])
    end
  end

  context "as an admin who is not the owner" do
    let(:user) { create(:membership, :admin, project:).user }

    it { is_expected.to permit_actions(%i[show update audit manage_webhooks]) }
    it { is_expected.to forbid_actions(%i[destroy restore]) }
  end

  context "as a plain member" do
    let(:user) { create(:membership, project:).user }

    it { is_expected.to permit_actions(%i[index create show]) }
    it { is_expected.to forbid_actions(%i[update destroy audit manage_webhooks]) }
  end

  context "as an outsider" do
    let(:user) { create(:user) }

    it { is_expected.to permit_actions(%i[index create]) }
    it { is_expected.to forbid_actions(%i[show update destroy restore audit manage_webhooks]) }
  end

  describe "Scope" do
    it "returns kept and discarded projects the user belongs to, annotated with their role" do
      user = create(:user)
      mine = create(:project, owner: user)
      trashed = create(:project, owner: user, discarded_at: 1.day.ago)
      joined = create(:membership, user:).project
      create(:project)

      scope = described_class::Scope.new(user, Project).resolve

      expect(scope).to contain_exactly(mine, trashed, joined)
      expect(scope.find(joined.id).current_role).to eq("member")
      expect(scope.find(mine.id).current_role).to eq("admin")
    end
  end
end
