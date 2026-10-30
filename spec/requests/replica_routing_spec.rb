require "rails_helper"

# Read replica routing (ADR 60). In the test environment the reading role points at the same database, so what is checked here is which ROLE each
# statement ran under, which is what decides whether production sends it to the replica or to the primary.
RSpec.describe "Read replica routing" do
  let(:user) { create(:user) }
  let!(:project) { create(:project, owner: user) }
  let!(:task) { create(:task, project: project, creator: user, title: "Land on the moon") }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }

  before do
    @original = [ Rails.configuration.x.replica_reads, Rails.configuration.x.replica_read_your_writes_seconds ]
    Rails.configuration.x.replica_reads = true
    Rails.configuration.x.replica_read_your_writes_seconds = 3
    allow(Rails).to receive(:cache).and_return(cache)
  end

  after { Rails.configuration.x.replica_reads, Rails.configuration.x.replica_read_your_writes_seconds = @original }

  # [role, sql] for every statement the block runs.
  def statements
    seen = []
    subscriber = ->(*, payload) { seen << [ ApplicationRecord.current_role, payload[:sql] ] unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:cached] }
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
    seen
  end

  def roles_for(pattern, statements) = statements.select { |_role, sql| sql.match?(pattern) }.map(&:first).uniq

  def outcome(name) = Observability::Metrics::REPLICA_READS.get(labels: { outcome: name.to_s })

  let(:list) { "/api/v1/projects/#{project.id}/tasks" }

  it "has a reading role, which cannot write" do
    ApplicationRecord.connected_to(role: :reading) do
      expect(ApplicationRecord.current_role).to eq(:reading)
      expect(ApplicationRecord.current_preventing_writes).to be(true)
      expect { User.create!(name: "Nope", email_address: "nope@example.com", password: "long-enough-pw-1") }.to raise_error(ActiveRecord::ReadOnlyError)
    end
  end

  it "runs the reads of an opted-in action under the reading role" do
    auth = auth_headers(user)
    seen = statements { get list, headers: auth }

    expect(response).to have_http_status(:ok)
    expect(roles_for(/FROM "tasks"/, seen)).to eq([ :reading ])
    expect(outcome(:replica)).to be >= 1
  end

  it "authenticates on the primary, including the usage stamp, never on the replica" do
    auth = auth_headers(user)
    Session.update_all(last_used_at: 1.day.ago)
    seen = statements { get list, headers: auth }

    expect(roles_for(/FROM "sessions"/, seen)).to eq([ :writing ])
    expect(seen.select { |_, sql| sql.start_with?("UPDATE \"sessions\"") }.map(&:first)).to eq([ :writing ])
    expect(Session.first.last_used_at).to be > 1.minute.ago
  end

  it "serves a person from the primary for a few seconds after they wrote, and from the replica again after" do
    api :post, list, { title: "Just created" }, as: user
    auth = auth_headers(user)

    seen = statements { get list, headers: auth }
    expect(data.pluck("title")).to include("Just created")
    expect(roles_for(/FROM "tasks"/, seen)).to eq([ :writing ])
    expect(outcome(:read_your_writes)).to be >= 1

    travel(4.seconds) do
      seen = statements { get list, headers: auth }
      expect(roles_for(/FROM "tasks"/, seen)).to eq([ :reading ])
    end
  end

  it "does not delay the read-your-writes window for someone else's writes: the marker is per person" do
    other = create(:user)
    create(:membership, project: project, user: other)
    api :post, list, { title: "By the other person" }, as: other
    auth = auth_headers(user)

    seen = statements { get list, headers: auth }

    expect(roles_for(/FROM "tasks"/, seen)).to eq([ :reading ])
  end

  it "routes only reads, and only the actions that opted in" do
    auth = auth_headers(user)
    seen = statements { get "/api/v1/me", headers: auth }
    expect(roles_for(/FROM "users"/, seen)).to eq([ :writing ])

    seen = statements { post list, params: { title: "x" }.to_json, headers: auth.merge("Content-Type" => "application/json") }
    expect(roles_for(/INSERT INTO "tasks"/, seen)).to eq([ :writing ])
  end

  it "does nothing at all when no replica is configured" do
    Rails.configuration.x.replica_reads = false
    auth = auth_headers(user)

    seen = statements { get list, headers: auth }

    expect(seen.map(&:first).uniq).to eq([ :writing ])
    expect(cache.exist?("replica:wrote:#{user.id}")).to be(false)
  end

  describe "when the replica cannot be reached" do
    before do
      real = ApplicationRecord.method(:connected_to)
      allow(ApplicationRecord).to receive(:connected_to) do |**options, &block|
        raise ActiveRecord::ConnectionNotEstablished, "replica is down" if options[:role] == :reading

        real.call(**options, &block)
      end
    end

    it "serves the request from the primary instead, and stops trying after three failures in a row" do
      auth = auth_headers(user)

      3.times do
        get list, headers: auth
        expect(response).to have_http_status(:ok)
        expect(data.pluck("title")).to include("Land on the moon")
      end
      expect(outcome(:replica_unreachable)).to be >= 3
      expect(ReplicaRouting.breaker.state).to eq(:open)

      before_calls = 0
      allow(ApplicationRecord).to receive(:connected_to).and_wrap_original { |original, **options, &block| before_calls += 1 if options[:role] == :reading; original.call(**options, &block) }
      get list, headers: auth
      expect(response).to have_http_status(:ok)
      expect(outcome(:breaker_open)).to be >= 1
      expect(before_calls).to eq(0) # the open breaker did not even try
    end
  end

  it "serves from the primary a query the replica cancelled because it conflicted with replication" do
    real = ApplicationRecord.method(:connected_to)
    allow(ApplicationRecord).to receive(:connected_to) do |**options, &block|
      raise ActiveRecord::SerializationFailure, "canceling statement due to conflict with recovery" if options[:role] == :reading

      real.call(**options, &block)
    end

    get list, headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    expect(outcome(:recovery_conflict)).to be >= 1
    expect(ReplicaRouting.breaker.state).to eq(:closed) # the replica is fine; that query was just too long for it
  end

  it "lets an ordinary error through untouched: a missing task is a 404 whichever role looked" do
    get "/api/v1/projects/0/tasks", headers: auth_headers(user)

    expect(response).to have_http_status(:not_found)
    expect(ReplicaRouting.breaker.state).to eq(:closed)
  end

  it "is declared on the read-heavy actions, and on nothing that writes" do
    controllers = Api::V1.constants.filter_map { |name| Api::V1.const_get(name) if name.to_s.end_with?("Controller") }
    routed = controllers.select { |controller| controller._process_action_callbacks.any? { |callback| callback.filter == :read_from_replica } }

    expect(routed.map { _1.name.demodulize }).to match_array(%w[TasksController ProjectsController SearchController ActivitiesController AuditEventsController OrganizationAuditEventsController CommentsController NotificationsController AnalyticsController])
  end
end
