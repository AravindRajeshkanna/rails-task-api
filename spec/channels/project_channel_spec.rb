require "rails_helper"

RSpec.describe ProjectChannel, type: :channel do
  let(:project) { create(:project) }
  let(:member) { create(:membership, project:).user }

  it "streams the project to its members" do
    stub_connection current_user: member

    subscribe(project_id: project.id)

    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_from("project:#{project.id}")
  end

  it "rejects non-members" do
    stub_connection current_user: create(:user)

    subscribe(project_id: project.id)

    expect(subscription).to be_rejected
  end

  it "rejects unknown and discarded projects" do
    stub_connection current_user: project.owner

    subscribe(project_id: 0)
    expect(subscription).to be_rejected

    project.discard
    subscribe(project_id: project.id)
    expect(subscription).to be_rejected
  end
end
