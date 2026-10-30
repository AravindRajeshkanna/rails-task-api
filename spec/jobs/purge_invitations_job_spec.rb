require "rails_helper"

RSpec.describe PurgeInvitationsJob do
  let(:owner) { create(:user) }
  let(:organization) { create(:organization, owner: owner) }

  def invite(address, **attributes)
    Current.set(session: Session.start_for!(owner).first) { create(:organization_invitation, organization: organization, invited_by: owner, email_address: address, **attributes) }
  end

  it "forgets invitations 90 days after they concluded, whichever way, and keeps the rest" do
    accepted = invite("a@example.com", accepted_at: 91.days.ago)
    revoked = invite("b@example.com", revoked_at: 91.days.ago)
    expired = invite("c@example.com", expires_at: 91.days.ago)
    recent = invite("d@example.com", revoked_at: 89.days.ago)
    pending = invite("e@example.com")

    described_class.perform_now

    expect(OrganizationInvitation.pluck(:id)).to contain_exactly(recent.id, pending.id)
    expect(OrganizationInvitation.where(id: [ accepted.id, revoked.id, expired.id ])).to be_empty
  end

  it "keeps the history of the invitation in the audit trail but not the address on it" do
    gone = invite("gone@example.com", expires_at: 91.days.ago)
    kept = invite("kept@example.com")

    described_class.perform_now

    expect(AuditEvent.where(auditable_type: "OrganizationInvitation", auditable_id: gone.id)).to exist
    expect(AuditEvent.where(auditable_type: "OrganizationInvitation", auditable_id: gone.id).pluck(:audit_changes).to_s).not_to include("gone@example.com")
    expect(AuditEvent.where(auditable_type: "OrganizationInvitation", auditable_id: kept.id).pluck(:audit_changes).to_s).to include("kept@example.com")
  end

  it "is scheduled every day" do
    schedule = YAML.load_file(Rails.root.join("config/recurring.yml")).dig("production", "prune_invitations")

    expect(schedule).to include("class" => "PurgeInvitationsJob", "schedule" => "every day at 4:40am")
  end
end
