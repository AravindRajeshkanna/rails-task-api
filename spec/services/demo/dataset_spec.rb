require "rails_helper"

RSpec.describe Demo::Dataset, type: :request do
  around do |example|
    original = Rails.configuration.x.demo_mode
    Rails.configuration.x.demo_mode = true
    example.run
  ensure
    Rails.configuration.x.demo_mode = original
  end

  it "refuses to touch a database that is not a demo" do
    Rails.configuration.x.demo_mode = false
    create(:user)

    expect { described_class.reset! }.to raise_error(/DEMO_MODE is not on/)
    expect(User.count).to eq(1)
  end

  it "does nothing from the nightly job unless it is a demo" do
    Rails.configuration.x.demo_mode = false
    create(:user)

    expect { ResetDemoJob.perform_now }.not_to change(User, :count)
  end

  describe "the data" do
    before { described_class.reset! }

    let(:demo) { User.find_by!(email_address: "demo@example.com") }

    it "is a small studio: people, an organization with teams, three projects" do
      expect(User.count).to eq(5)
      expect(Organization.sole).to have_attributes(name: "Acme Studio")
      expect(Team.pluck(:name)).to contain_exactly("Design", "Engineering")
      expect(Project.pluck(:name)).to contain_exactly("Website Relaunch", "Mobile App", "Personal Notes")
      expect(ProjectTeam.count).to eq(4)
      expect(Task.count).to be >= 20
    end

    it "lets the demo user sign in with the published password and see everything they should" do
      api :post, "/api/v1/session", { email_address: "demo@example.com", password: described_class::PASSWORD }
      expect(response).to have_http_status(:created)

      api :get, "/api/v1/projects", as: demo
      expect(data.pluck("name")).to contain_exactly("Website Relaunch", "Mobile App", "Personal Notes")
    end

    it "gives the demo something of everything: overdue and due-tomorrow tasks, every status and priority, tags, comments" do
      expect(Task.overdue.count).to be >= 2
      expect(Task.where(due_on: Date.tomorrow).where.not(status: :done)).to exist
      expect(Task.statuses.keys.map { |status| Task.where(status: status).count }).to all(be_positive)
      expect(Task.priorities.keys.map { |priority| Task.where(priority: priority).count }).to all(be_positive)
      expect(Tag.count).to be >= 8
      expect(Comment.count).to be >= 5
    end

    it "fills the audit log, the inbox and the search index by going through the models" do
      expect(AuditEvent.where(project_id: Project.find_by!(name: "Website Relaunch").id).count).to be > 10
      expect(AuditEvent.where(auditable_type: "Team").count).to eq(2)
      expect(Notification.where(user: demo)).to exist
      expect(Task.full_text("landing page").count).to be >= 2
    end

    it "shows the organization's teams working through the access rules" do
      riley = User.find_by!(email_address: "riley@example.com")

      api :get, "/api/v1/projects", as: riley
      expect(data.pluck("name")).to contain_exactly("Website Relaunch", "Mobile App") # through the Design team; never "Personal Notes"
      expect(data.pluck("role").uniq).to eq([ "member" ])

      api :get, "/api/v1/projects", as: User.find_by!(email_address: "sam@example.com")
      expect(data.to_h { [ _1["name"], _1["role"] ] }).to eq("Website Relaunch" => "admin", "Mobile App" => "admin") # the Engineering team has admin on both
    end

    it "is rebuilt from scratch: running it again replaces everything, including what visitors added" do
      demo_project = Project.find_by!(name: "Website Relaunch")
      create(:task, project: demo_project, title: "Visitor graffiti")
      User.create!(name: "Visitor", email_address: "visitor@example.com", password: "visitor-password")
      tasks_before = Task.where.not(title: "Visitor graffiti").count

      described_class.reset!

      expect(Task.where(title: "Visitor graffiti")).to be_empty
      expect(User.where(email_address: "visitor@example.com")).to be_empty
      expect([ User.count, Task.count ]).to eq([ 5, tasks_before ])
      expect(Task.minimum(:id)).to eq(1) # identities restart
    end
  end
end
