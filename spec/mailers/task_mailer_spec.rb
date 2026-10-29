require "rails_helper"

RSpec.describe TaskMailer do
  let(:project) { create(:project, name: "Apollo") }
  let(:assignee) { create(:membership, project:, user: create(:user, name: "Grace", email_address: "grace@example.com")).user }
  let(:task) { create(:task, project:, assignee:, title: "Land on the moon", due_on: Date.new(2026, 12, 25)) }

  describe "#assigned" do
    subject(:mail) { described_class.assigned(task) }

    it "tells the assignee what they were given, with a link to the front end" do
      expect(mail).to have_attributes(to: [ "grace@example.com" ], subject: "You were assigned: Land on the moon")
      expect(mail.body.to_s).to include("Grace", "Apollo", "Land on the moon", "December 25, 2026")
      expect(mail.body.to_s).to include("#{Rails.configuration.x.frontend_url}/projects/#{project.id}/tasks/#{task.id}")
    end

    it "uses the configured sender" do
      expect(mail.from).to eq([ "no-reply@example.com" ])
    end
  end

  describe "#due_soon" do
    subject(:mail) { described_class.due_soon(task) }

    it "warns that the task is due tomorrow" do
      expect(mail).to have_attributes(to: [ "grace@example.com" ], subject: "Due tomorrow: Land on the moon")
      expect(mail.body.to_s).to include("due tomorrow", "Land on the moon")
    end
  end
end
