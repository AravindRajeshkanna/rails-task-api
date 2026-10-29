require "rails_helper"

RSpec.describe Events::OutboxRelay do
  let(:topic) { "arn:aws:sns:us-east-1:123456789012:task-api-events" }
  let(:sns) { Aws::SNS::Client.new(stub_responses: true, region: "us-east-1") }

  around do |example|
    original = Rails.configuration.x.events.sns_topic_arn
    Rails.configuration.x.events.sns_topic_arn = topic
    Events::SnsPublisher.client = sns
    example.run
  ensure
    Rails.configuration.x.events.sns_topic_arn = original
    Events::SnsPublisher.client = nil
  end

  def add_event(type = "task.created", id: SecureRandom.uuid, **attributes)
    OutboxEvent.create!(event_id: id, event_type: type, created_at: Time.current, **attributes,
                        payload: { specversion: "1.0", id: id, source: "task-api", type: type, projectid: 7, data: {} })
  end

  def published_ids = sns.api_requests.map { |request| JSON.parse(request[:params][:message])["id"] }

  describe "publishing" do
    it "sends pending events oldest first with the attributes subscriptions filter on, and marks them published" do
      first = add_event("task.created")
      second = add_event("task.assigned")

      expect(described_class.call).to eq(2)

      expect(published_ids).to eq([ first.event_id, second.event_id ])
      expect(sns.api_requests.last[:params][:message_attributes]).to include("type" => { data_type: "String", string_value: "task.assigned" })
      expect([ first, second ].map { _1.reload.published_at }).to all(be_present)
      expect(OutboxEvent.pending).to be_empty
    end

    it "does not send an event twice" do
      add_event

      2.times { described_class.call }

      expect(sns.api_requests.size).to eq(1)
    end

    it "works through a backlog bigger than one batch" do
      Array.new(described_class::BATCH + 20) { add_event }

      expect(described_class.call).to eq(described_class::BATCH + 20)
      expect(OutboxEvent.pending).to be_empty
    end

    it "stops at its time budget instead of running for ever, leaving the rest for the next run" do
      Array.new(3) { add_event }
      stub_const("#{described_class}::BATCH", 1)
      stub_const("#{described_class}::TIME_BUDGET", 0.seconds)

      expect(described_class.call).to eq(1)
      expect(OutboxEvent.pending.count).to eq(2)
    end

    it "does nothing without a topic, and keeps the events for when there is one" do
      add_event
      Rails.configuration.x.events.sns_topic_arn = nil

      expect(described_class.call).to eq(0)
      expect(OutboxEvent.pending.count).to eq(1)
      expect(sns.api_requests).to be_empty
    end
  end

  describe "when SNS fails" do
    it "keeps the event, remembers why, and backs off before trying again" do
      stored = add_event
      sns.stub_responses(:publish, "ThrottledException")

      expect(described_class.call).to eq(0)

      stored.reload
      expect(stored).to have_attributes(published_at: nil, attempts: 1, locked_until: nil)
      expect(stored.last_error).to include("Retryable")
      expect(stored.available_at).to be_between(1.second.from_now, 5.seconds.from_now)

      expect { described_class.call }.not_to(change { sns.api_requests.size }) # not due yet
    end

    it "tries again when it is due, and delivers once SNS is back" do
      stored = add_event
      sns.stub_responses(:publish, "InternalErrorException")
      described_class.call

      sns.stub_responses(:publish, {})
      travel(10.seconds) { expect(described_class.call).to eq(1) }

      expect(stored.reload).to have_attributes(published_at: be_present, last_error: nil, attempts: 2)
    end

    it "backs off exponentially up to a cap" do
      stored = add_event(attempts: 4)
      sns.stub_responses(:publish, "ThrottledException")
      described_class.call # this is attempt 5: 2**5 seconds

      expect(stored.reload.available_at).to be_between(31.seconds.from_now, 33.seconds.from_now)

      stored.update!(attempts: 20, available_at: 1.minute.ago)
      described_class.call
      expect(stored.reload.available_at).to be_between(14.minutes.from_now, 16.minutes.from_now)
    end

    it "reports what went wrong without raising, and one bad event does not hold up the rest" do
      bad = add_event("task.created", id: "bad")
      good = add_event("task.updated", id: "good")
      sns.stub_responses(:publish, ->(context) { JSON.parse(context.params[:message])["id"] == "bad" ? "InvalidParameterException" : {} })

      expect(Rails.error).to receive(:report).with(an_instance_of(Aws::SNS::Errors::InvalidParameterException), hash_including(handled: true, context: hash_including(outbox_event: "bad")))
      expect { described_class.call }.not_to raise_error

      expect(good.reload.published_at).to be_present
      expect(bad.reload).to have_attributes(published_at: nil, last_error: include("InvalidParameter"))
    end
  end

  describe "leases" do
    it "gives two relays different events, never the same one" do
      Array.new(6) { add_event }

      a = OutboxEvent.claim(limit: 4, lease: 2.minutes)
      b = OutboxEvent.claim(limit: 4, lease: 2.minutes)

      expect(a.size).to eq(4)
      expect(b.size).to eq(2)
      expect(a.map(&:id) & b.map(&:id)).to be_empty
    end

    it "gives a crashed relay's events to the next one once the lease has run out, and not before" do
      add_event
      OutboxEvent.claim(limit: 10, lease: 2.minutes) # the relay claims, then dies

      expect(OutboxEvent.claim(limit: 10, lease: 2.minutes)).to be_empty
      travel(3.minutes) { expect(OutboxEvent.claim(limit: 10, lease: 2.minutes).size).to eq(1) }
    end

    it "keeps working from several processes at once without double sending" do
      Array.new(40) { add_event }
      ids = Queue.new

      threads = Array.new(4) do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection { OutboxEvent.claim(limit: 15, lease: 2.minutes).each { |event| ids << event.id } }
        end
      end
      threads.each(&:join)
      claimed = Array.new(ids.size) { ids.pop }

      expect(claimed.size).to eq(claimed.uniq.size)
      expect(claimed.size).to eq(40)
    end
  end
end

RSpec.describe OutboxRelayJob do
  it "runs the relay" do
    expect(Events::OutboxRelay).to receive(:call)

    described_class.perform_now
  end

  it "is limited to one at a time, dropping a wake-up that arrives while one runs" do
    expect(described_class.concurrency_limit).to eq(1)
    expect(described_class.concurrency_on_conflict).to eq(:discard)
  end

  it "is swept every minute" do
    schedule = YAML.load_file(Rails.root.join("config/recurring.yml")).dig("production", "outbox_relay")

    expect(schedule).to include("class" => "OutboxRelayJob", "schedule" => "every minute")
  end
end

RSpec.describe PurgeOutboxJob do
  it "deletes published events after a week and never touches pending ones" do
    make = ->(**attributes) { OutboxEvent.create!(event_id: SecureRandom.uuid, event_type: "task.created", payload: {}, created_at: 30.days.ago, **attributes) }
    old = make.call(published_at: 8.days.ago)
    recent = make.call(published_at: 6.days.ago)
    stuck = make.call(published_at: nil)

    described_class.perform_now

    expect(OutboxEvent.pluck(:id)).to contain_exactly(recent.id, stuck.id)
    expect(OutboxEvent.exists?(old.id)).to be(false)
  end
end
