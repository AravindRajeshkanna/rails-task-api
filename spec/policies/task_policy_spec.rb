require "rails_helper"

RSpec.describe TaskPolicy do
  subject(:policy) { described_class.new(user, task) }

  let(:project) { create(:project) }
  let(:author) { create(:membership, project:).user }
  let(:task) { create(:task, project:, creator: author) }

  context "as the task's creator (plain member)" do
    let(:user) { author }

    it { is_expected.to permit_actions(%i[index show create update destroy]) }
    it { is_expected.to forbid_action(:restore) }
  end

  context "as another plain member" do
    let(:user) { create(:membership, project:).user }

    it { is_expected.to permit_actions(%i[index show create update]) }
    it { is_expected.to forbid_actions(%i[destroy restore]) }
  end

  context "as a project admin" do
    let(:user) { project.owner }

    it { is_expected.to permit_actions(%i[index show create update destroy]) }

    it "may restore discarded tasks" do
      task.discard

      expect(policy).to permit_action(:restore)
      expect(policy).to forbid_actions(%i[show update destroy])
    end
  end

  context "as an outsider" do
    let(:user) { create(:user) }

    it { is_expected.to forbid_actions(%i[index show create update destroy restore]) }
  end

  context "when the project is discarded" do
    let(:user) { project.owner }

    it "locks the tasks" do
      project.discard

      expect(policy).to forbid_actions(%i[show create update destroy restore])
    end
  end

  describe "Scope" do
    it "only includes tasks from kept projects the user belongs to" do
      user = create(:user)
      visible = create(:task, project: create(:membership, user:).project)
      hidden_project = create(:membership, user:).project
      hidden = create(:task, project: hidden_project)
      hidden_project.discard
      create(:task)

      expect(described_class::Scope.new(user, Task).resolve).to contain_exactly(visible)
      expect(Task.exists?(hidden.id)).to be(true)
    end
  end
end
