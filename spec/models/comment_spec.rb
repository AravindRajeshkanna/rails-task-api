require "rails_helper"

RSpec.describe Comment do
  subject { build(:comment) }

  it { is_expected.to belong_to(:task).counter_cache(true) }
  it { is_expected.to belong_to(:user) }
  it { is_expected.to validate_presence_of(:body) }
  it { is_expected.to validate_length_of(:body).is_at_most(5_000) }

  it "emits comment.created with the project id" do
    task = create(:task)
    comment = nil
    recorder = record_events { comment = create(:comment, task:) }

    expect(recorder.payloads("comment.created").sole).to include(project_id: task.project_id, subject: comment.to_global_id.to_s)
  end
end
