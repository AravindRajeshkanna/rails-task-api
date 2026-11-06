require "rails_helper"

# What leaves with a person and what stays for the people they worked with (ADR 67, docs/data-protection.md).
RSpec.describe AccountErasure do
  let(:user) { create(:user, name: "Ada Lovelace", email_address: "ada@example.com") }
  let(:colleague) { create(:user) }
  let!(:organization) { create(:organization, owner: colleague) }
  let!(:project) { create(:project, owner: colleague, organization: organization) }

  before do
    create(:organization_membership, organization: organization, user: user)
    create(:membership, project: project, user: user)
  end

  it "turns the user into a tombstone that cannot sign in, and frees the address" do
    Session.start_for!(user, ip_address: "203.0.113.7", user_agent: "RSpec")
    user.avatar.attach(io: StringIO.new("png"), filename: "me.png", content_type: "image/png")

    expect { described_class.call(user) }.to have_enqueued_job(ActiveStorage::PurgeJob)

    user.reload
    expect(user.avatar).not_to be_attached
    expect(user).to be_erased
    expect(user).to have_attributes(name: "Deleted user", email_address: "erased-#{user.id}@erased.invalid", password_digest: nil, auth_subject: nil)
    expect(user.authenticate("correct-horse-battery")).to be(false)
    expect(Session.where(user_id: user.id)).to be_empty
    expect(User.new(name: "Ada", email_address: "ada@example.com", password: "another-password-1")).to be_valid
  end

  it "removes the person from projects, organizations, teams and everything that followed them" do
    team = create(:team, organization: organization)
    create(:team_membership, team: team, user: user)
    create(:notification_setting, user: user)
    create(:notification_mute, user: user)
    create(:notification, user: user, project: project, task: create(:task, project: project, creator: colleague))
    IdempotencyKey.create!(user: user, key: "k", request_fingerprint: "f", locked_at: 1.minute.ago)

    described_class.call(user)

    expect(Membership.where(user_id: user.id)).to be_empty
    expect(OrganizationMembership.where(user_id: user.id)).to be_empty
    expect(TeamMembership.where(user_id: user.id)).to be_empty
    expect([ NotificationSetting, NotificationMute, Notification, IdempotencyKey ].map { |model| model.where(user_id: user.id).count }).to eq([ 0, 0, 0, 0 ])
  end

  it "keeps the work: tasks and comments stay, attributed to the tombstone, and assigned tasks lose their assignee" do
    mine = create(:task, project: project, creator: user, assignee: user)
    theirs = create(:task, project: project, creator: colleague, assignee: user)
    comment = create(:comment, task: theirs, user: user, body: "On it")
    before = theirs.reload.updated_at

    travel(1.minute) { described_class.call(user) }

    expect(mine.reload).to have_attributes(creator_id: user.id, assignee_id: nil)
    expect(theirs.reload.assignee_id).to be_nil
    expect(theirs.updated_at).to be > before # cached copies of the task go stale
    expect(comment.reload).to have_attributes(user_id: user.id, body: "On it")
    expect(comment.user.name).to eq("Deleted user")
  end

  it "forgets invitations addressed to the person, including the address in the audit trail, and leaves other invitations alone" do
    elsewhere = create(:organization, owner: colleague) # an organization the person has not joined (yet)
    Current.set(session: Session.start_for!(colleague).first) do
      @theirs = create(:organization_invitation, organization: elsewhere, invited_by: colleague, email_address: "ada@example.com")
      @someone_elses = create(:organization_invitation, organization: elsewhere, invited_by: colleague, email_address: "grace@example.com")
    end

    described_class.call(user)

    expect(OrganizationInvitation.exists?(@theirs.id)).to be(false)
    expect(OrganizationInvitation.exists?(@someone_elses.id)).to be(true)
    trail = AuditEvent.where(auditable_type: "OrganizationInvitation")
    expect(trail.where(auditable_id: @theirs.id)).to exist # the fact that an invitation existed stays
    expect(trail.where(auditable_id: @theirs.id).pluck(:audit_changes).to_s).not_to include("ada@example.com")
    expect(trail.where(auditable_id: @someone_elses.id).pluck(:audit_changes).to_s).to include("grace@example.com")
  end

  it "does nothing the second time" do
    described_class.call(user)
    erased_at = user.reload.erased_at

    expect { described_class.call(user) }.not_to change { user.reload.attributes }
    expect(user.erased_at).to eq(erased_at)
  end

  it "records that it happened, with the id and nothing that identifies the person" do
    events = record_events { described_class.call(user) }

    expect(events.payloads("user.erased").sole).to eq(user_id: user.id)
  end

  # The services that hold something of the person are told through the outbox, in the transaction that erased them (ADR 79).
  describe "telling the other services" do
    let(:user) { create(:user, name: "Ada Lovelace", email_address: "ada@example.com", auth_subject: "4d9a4e8e-5f35-4a27-9d44-5c4ee3f1a111", password_digest: nil) }
    let(:published) { OutboxEvent.where(event_type: "user.erased") }

    around do |example|
      original = Rails.configuration.x.events.sns_topic_arn
      Rails.configuration.x.events.sns_topic_arn = "arn:aws:sns:us-east-1:123456789012:task-api-events"
      example.run
    ensure
      Rails.configuration.x.events.sns_topic_arn = original
    end

    it "writes user.erased to the outbox with the two ids that find the person elsewhere, and not the address or the name" do
      described_class.call(user)

      event = published.sole.payload
      expect(event).to include("specversion" => "1.0", "type" => "user.erased", "source" => "task-api", "subject" => user.to_global_id.to_s,
                               "data" => { "user_id" => user.id, "auth_subject" => "4d9a4e8e-5f35-4a27-9d44-5c4ee3f1a111" })
      expect(event).not_to have_key("projectid")
      expect(published.sole.payload.to_json).not_to include("ada@example.com", "Ada", "Lovelace")
    end

    it "leaves out the subject for someone the Auth service never knew, and says so by what it carries" do
      local = create(:user, email_address: "local@example.com")

      described_class.call(local)

      expect(published.sole.payload["data"]).to eq("user_id" => local.id)
    end

    it "is in the transaction of the erasure: an erasure that fails leaves no event, one that works leaves exactly one" do
      allow_any_instance_of(User).to receive(:update_columns).and_raise("the tombstone failed")

      expect { described_class.call(user) }.to raise_error("the tombstone failed")
      expect(published).to be_empty
      expect(user.reload).not_to be_erased

      allow_any_instance_of(User).to receive(:update_columns).and_call_original
      described_class.call(user)
      expect(published.count).to eq(1)
    end

    it "does not say it twice, however often it is asked to erase" do
      2.times { described_class.call(user) }

      expect(published.count).to eq(1)
    end

    it "wakes the relay once the erasure has committed" do
      expect { described_class.call(user) }.to have_enqueued_job(OutboxRelayJob)
    end

    it "writes nothing where no events go anywhere (no topic is configured)" do
      Rails.configuration.x.events.sns_topic_arn = nil

      described_class.call(user)

      expect(published).to be_empty
    end

    it "keeps the identity's subject on the tombstone, so a token issued before the identity was deleted cannot make the person again" do
      described_class.call(user)

      expect(user.reload).to have_attributes(auth_subject: "4d9a4e8e-5f35-4a27-9d44-5c4ee3f1a111", password_digest: nil, email_address: "erased-#{user.id}@erased.invalid")
    end
  end

  describe "refusing, and changing nothing" do
    it "refuses while the person owns a project that is not archived" do
      create(:project, owner: user)
      create(:project, owner: user)

      expect { described_class.call(user) }.to raise_error(described_class::Blocked, /own 2 projects/) { |error| expect(error.code).to eq("owns_projects") }
      expect(user.reload).not_to be_erased
      expect(Membership.where(user_id: user.id)).to exist
    end

    it "lets go once the projects are archived, and the tombstone still owns them" do
      archived = create(:project, :discarded, owner: user)

      described_class.call(user)

      expect(archived.reload.owner_id).to eq(user.id)
      expect(user.reload).to be_erased
    end

    it "refuses the last owner of an organization, but not one of several" do
      own = create(:organization, owner: user)

      expect { described_class.call(user) }.to raise_error(described_class::Blocked, /last owner of #{own.name}/) { |error| expect(error.code).to eq("last_organization_owner") }

      create(:organization_membership, :owner, organization: own, user: create(:user))
      expect { described_class.call(user) }.not_to raise_error
    end
  end
end
