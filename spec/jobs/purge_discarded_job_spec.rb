require "rails_helper"

RSpec.describe PurgeDiscardedJob do
  let(:project) { create(:project) }

  def old = (Rails.configuration.x.discard_retention + 1.day).ago
  def recent = 3.days.ago

  it "permanently deletes tasks and projects discarded longer than the retention window" do
    old_task = create(:task, project:, discarded_at: old)
    recent_task = create(:task, project:, discarded_at: recent)
    kept_task = create(:task, project:)
    old_project = create(:project, discarded_at: old)
    recent_project = create(:project, discarded_at: recent)

    described_class.perform_now

    expect(Task.exists?(old_task.id)).to be(false)
    expect(Task.where(id: [ recent_task.id, kept_task.id ]).count).to eq(2)
    expect(Project.exists?(old_project.id)).to be(false)
    expect(Project.where(id: [ project.id, recent_project.id ]).count).to eq(2)
  end

  it "takes dependent records with it but keeps the audit trail" do
    task = create(:task, project:, tag_names: %w[a])
    create(:comment, task:)
    task.update!(discarded_at: old)

    expect { described_class.perform_now }
      .to change(Comment, :count).by(-1)
      .and change(Tagging, :count).by(-1)

    expect(AuditEvent.where(auditable_type: "Task", auditable_id: task.id)).to exist
  end

  it "deletes a discarded project together with its tasks" do
    doomed = create(:project, discarded_at: old)
    create_list(:task, 2, project: doomed)

    expect { described_class.perform_now }.to change(Task, :count).by(-2)
  end

  it "resumes from its cursor when the worker is interrupted" do
    tasks = create_list(:task, 3, project:, discarded_at: old)

    # The queue adapter reports "stopping" after the first task, like a worker shutting down on deploy.
    job = described_class.new
    calls = 0
    allow(job.queue_adapter).to receive(:stopping?) { (calls += 1) > 1 }

    expect { job.perform_now }.to have_enqueued_job(described_class)
    remaining = Task.where(id: tasks.map(&:id)).count
    expect(remaining).to be_between(1, 2) # progress was made, but not finished

    perform_enqueued_jobs(only: described_class)
    expect(Task.where(id: tasks.map(&:id))).to be_empty
  end
end
