require "rails_helper"

RSpec.describe AuditEvent do
  let(:event) do
    project = create(:project)
    AuditEvent.create!(project:, auditable: project, action: "update", audit_changes: { "name" => %w[a b] })
  end

  it "is append-only" do
    expect { event.update!(action: "tampered") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect { event.destroy }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "survives hard deletion of the audited record" do
    project = event.project
    project.destroy!

    expect(AuditEvent.find(event.id).project_id).to be_nil
  end
end
