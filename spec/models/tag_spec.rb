require "rails_helper"

RSpec.describe Tag do
  subject { build(:tag) }

  it { is_expected.to belong_to(:project) }
  it { is_expected.to have_many(:tasks).through(:taggings) }
  it { is_expected.to validate_presence_of(:name) }
  it { is_expected.to validate_length_of(:name).is_at_most(40) }
  it { is_expected.to validate_uniqueness_of(:name).scoped_to(:project_id).case_insensitive }

  it "normalizes names" do
    expect(create(:tag, name: "  Needs   Review ").name).to eq("needs review")
  end

  it "allows the same name in different projects" do
    create(:tag, name: "bug")

    expect(build(:tag, name: "bug")).to be_valid
  end

  describe Tagging do
    it "rejects a tag from another project" do
      task = create(:task)
      foreign_tag = create(:tag)

      tagging = Tagging.new(task:, tag: foreign_tag)
      expect(tagging).not_to be_valid
      expect(tagging.errors[:tag]).to include("must belong to the task's project")
    end
  end
end
