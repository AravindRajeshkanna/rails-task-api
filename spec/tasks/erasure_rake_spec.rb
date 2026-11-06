require "rails_helper"
require "rake"

# The way to send an erasure again (docs/runbooks/account-erasure.md): for a consumer that was down longer than the queue keeps messages, and for people erased
# before the event existed. The event makes the Auth service delete an identity, so what matters most is whom it can name.
RSpec.describe "erasure rake tasks" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("erasure:publish")
  end

  let(:published) { [] }
  let!(:ada) { create(:user, email_address: "ada@example.com", auth_subject: "4d9a4e8e-5f35-4a27-9d44-5c4ee3f1a111", password_digest: nil).tap { |user| AccountErasure.call(user) } }
  let!(:grace) { create(:user, email_address: "grace@example.com") }

  around do |example|
    original = Rails.configuration.x.events.sns_topic_arn
    Rails.configuration.x.events.sns_topic_arn = "arn:aws:sns:us-east-1:123456789012:task-api-events"
    example.run
  ensure
    Rails.configuration.x.events.sns_topic_arn = original
  end

  before { allow(Events::SnsPublisher).to receive(:publish) { |envelope| published << envelope } }

  def run(env = {})
    original = ENV.to_h.slice(*env.keys)
    env.each { |key, value| ENV[key] = value }
    Rake::Task["erasure:publish"].reenable
    output = StringIO.new
    $stdout = output
    $stderr = StringIO.new
    begin
      Rake::Task["erasure:publish"].invoke
    rescue SystemExit => error
      [ output.string, error.message ]
    else
      [ output.string, nil ]
    ensure
      $stdout = STDOUT
      $stderr = STDERR
      env.each_key { |key| original.key?(key) ? ENV[key] = original[key] : ENV.delete(key) }
    end
  end

  it "sends the event of each erased person asked for, as the outbox would have, with the ids and nothing else" do
    printed, failure = run("USER_IDS" => ada.id.to_s)

    expect(failure).to be_nil
    expect(published.sole).to include(id: "user.erased:#{ada.id}", type: "user.erased", source: "task-api", data: { user_id: ada.id, auth_subject: "4d9a4e8e-5f35-4a27-9d44-5c4ee3f1a111" })
    expect(published.sole.to_json).not_to include("ada@example.com")
    expect(printed).to include("Published user.erased for 1 erased person.")
  end

  it "never names somebody who has not been erased, however it is asked: the event deletes an identity" do
    printed, = run("USER_IDS" => "#{ada.id},#{grace.id}")

    expect(published.map { |envelope| envelope.dig(:data, :user_id) }).to eq([ ada.id ])
    expect(printed).to include("1 of the ids asked for is not an erased user and was left alone.")
    expect(User.find(grace.id)).not_to be_erased
  end

  it "sends everyone erased since a date" do
    old = create(:user).tap { |user| AccountErasure.call(user); user.update_columns(erased_at: 40.days.ago) }

    run("SINCE" => 1.week.ago.to_date.iso8601)

    expect(published.map { |envelope| envelope.dig(:data, :user_id) }).to eq([ ada.id ])
    expect(published.map { |envelope| envelope[:id] }).not_to include("user.erased:#{old.id}")
  end

  it "says whom it needs rather than sending everyone, and refuses where there is nowhere to send" do
    _, failure = run

    expect(failure).to match(/Say whom/)
    expect(published).to be_empty

    Rails.configuration.x.events.sns_topic_arn = nil
    _, failure = run("USER_IDS" => ada.id.to_s)
    expect(failure).to match(/EVENTS_SNS_TOPIC_ARN is not set/)
    expect(published).to be_empty
  end

  it "can be run twice: the same event, the same id" do
    2.times { run("USER_IDS" => ada.id.to_s) }

    expect(published.map { |envelope| envelope[:id] }.uniq).to eq([ "user.erased:#{ada.id}" ])
  end
end
