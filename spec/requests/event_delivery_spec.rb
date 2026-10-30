require "rails_helper"

RSpec.describe "From a request to SNS", type: :request do
  include ActiveJob::TestHelper

  let(:sns) { Aws::SNS::Client.new(stub_responses: true, region: "us-east-1") }
  let(:alice) { create(:user) }
  let(:bob) { create(:user, name: "Bob", email_address: "bob@example.com") }
  let!(:project) { create(:project, owner: alice) }

  around do |example|
    original = Rails.configuration.x.events.sns_topic_arn
    Rails.configuration.x.events.sns_topic_arn = "arn:aws:sns:us-east-1:123456789012:task-api-events"
    Events::SnsPublisher.client = sns
    create(:membership, project: project, user: bob)
    OutboxEvent.delete_all
    example.run
  ensure
    Rails.configuration.x.events.sns_topic_arn = original
    Events::SnsPublisher.client = nil
  end

  it "keeps an event through an SNS outage and delivers it, exactly once, when SNS returns" do
    sns.stub_responses(:publish, "InternalErrorException")

    api :post, "/api/v1/projects/#{project.id}/tasks", { title: "Land on the moon", assignee_id: bob.id }, as: alice
    expect(response).to have_http_status(:created)
    expect(OutboxEvent.pending.pluck(:event_type)).to contain_exactly("task.created", "task.assigned")

    Events::OutboxRelay.call # SNS is down: everything stays, nothing is lost
    expect(OutboxEvent.pending.count).to eq(2)
    expect(OutboxEvent.pending.pluck(:attempts)).to all(eq(1))

    sns.stub_responses(:publish, {})
    travel(10.seconds) { Events::OutboxRelay.call }
    Events::OutboxRelay.call # and again: nothing left to send

    messages = sns.api_requests.select { |request| request[:operation_name] == :publish && request[:context].http_response.status_code == 200 }
                  .map { |request| JSON.parse(request[:params][:message]) }
    expect(messages.pluck("type")).to contain_exactly("task.created", "task.assigned")
    assigned = messages.find { |message| message["type"] == "task.assigned" }
    expect(assigned.dig("data", "recipient", "email_address")).to eq("bob@example.com")
    expect(OutboxEvent.pending).to be_empty
  end
end
