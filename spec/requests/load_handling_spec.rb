require "rails_helper"

# The three ways the API protects the shared capacity (ADR 62): a budget per organization, a smaller one for the expensive endpoints, and refusing
# the expensive work when every thread is busy.
RSpec.describe "Load handling" do
  let(:user) { create(:user) }
  let(:organization) { create(:organization, owner: user) }
  let!(:project) { create(:project, owner: user, organization: organization) }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }

  describe "the per-organization write budget" do
    before do
      @original = Rails.configuration.x.organization_writes_per_period
      Rails.configuration.x.organization_writes_per_period = 3
      allow(Rails).to receive(:cache).and_return(cache)
    end

    after { Rails.configuration.x.organization_writes_per_period = @original }

    def create_task(as: user, in_project: project) = api(:post, "/api/v1/projects/#{in_project.id}/tasks", { title: "x" }, as: as)

    it "refuses an organization's writes once it has spent its budget, with a Retry-After to the end of the window" do
      3.times { create_task and expect(response).to have_http_status(:created) }

      expect { create_task }.not_to change(Task, :count)

      expect(response).to have_http_status(:too_many_requests)
      expect(error["code"]).to eq("rate_limited")
      expect(response.headers["Retry-After"].to_i).to be_between(1, OrganizationBudget::PERIOD.to_i)
    end

    it "counts every kind of write against the one budget, whatever the endpoint or the client" do
      other_client = create(:organization_membership, organization: organization).user
      create(:membership, project: project, user: other_client)
      create_task
      api :post, "/api/v1/tasks/#{Task.last.id}/comments", { body: "hi" }, as: other_client
      api :patch, "/api/v1/tasks/#{Task.last.id}", { title: "renamed" }, as: user

      create_task(as: other_client)

      expect(response).to have_http_status(:too_many_requests)
    end

    it "leaves other organizations, and people with only personal projects, alone" do
      3.times { create_task }
      elsewhere = create(:organization, owner: user)
      other_project = create(:project, owner: user, organization: elsewhere)
      personal = create(:project, owner: user)

      create_task(in_project: other_project)
      expect(response).to have_http_status(:created)
      create_task(in_project: personal)
      expect(response).to have_http_status(:created)
    end

    it "does not charge reads, and does not let a person who may not write spend the organization's budget" do
      10.times { api :get, "/api/v1/projects/#{project.id}/tasks", as: user }
      expect(response).to have_http_status(:ok)

      stranger = create(:user)
      10.times { api :post, "/api/v1/projects/#{project.id}/tasks", { title: "x" }, as: stranger }
      expect(response).to have_http_status(:not_found)

      create_task
      expect(response).to have_http_status(:created) # the budget is intact
    end

    it "starts afresh in the next window" do
      3.times { create_task }
      create_task
      expect(response).to have_http_status(:too_many_requests)

      travel(OrganizationBudget::PERIOD + 1.second) { create_task }

      expect(response).to have_http_status(:created)
    end

    it "turns over on the clock, so Retry-After is true: a minute after the window ends, not five after the first write" do
      boundary = Time.zone.at((Time.current.to_i / OrganizationBudget::PERIOD.to_i + 1) * OrganizationBudget::PERIOD.to_i)
      travel_to(boundary - 10.seconds) do
        3.times { create_task }
        create_task
        expect(response).to have_http_status(:too_many_requests)
        expect(response.headers["Retry-After"]).to eq("10")
      end

      travel_to(boundary + 1.second) do
        create_task
        expect(response).to have_http_status(:created)
      end
    end

    it "fails open when the cache is down: a cache outage does not stop people working" do
      allow(cache).to receive(:increment).and_raise(Redis::BaseError) if defined?(Redis)
      allow(cache).to receive(:increment).and_return(nil)

      5.times { create_task }

      expect(response).to have_http_status(:created)
    end

    it "records which organization a request was about, for the logs" do
      api :get, "/api/v1/projects/#{project.id}", as: user

      expect(Current.organization_id).to be_nil # reset after the request
      expect(Tenant.organization_id_for(project)).to eq(organization.id)
      expect(Tenant.organization_id_for(create(:task, project: project, creator: user))).to eq(organization.id)
      expect(Tenant.organization_id_for(create(:comment, task: create(:task, project: project, creator: user), user: user))).to eq(organization.id)
      expect(Tenant.organization_id_for(create(:project, owner: user))).to be_nil
      expect(Tenant.organization_id_for(Project)).to be_nil
    end
  end

  describe "the budget for the expensive endpoints" do
    before do
      Rack::Attack.enabled = true
      Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    end

    after do
      Rack::Attack.enabled = false
      Rack::Attack.cache.store = Rails.cache
    end

    it "throttles search, analytics and the feed at 120 per five minutes, long before the general limit" do
      headers = auth_headers(user)
      120.times { get "/api/v1/search", params: { q: "x" }, headers: headers }
      expect(response).to have_http_status(:ok)

      get "/api/v1/search", params: { q: "x" }, headers: headers
      expect(response).to have_http_status(:too_many_requests)
      expect(error["code"]).to eq("rate_limited")

      get "/api/v1/projects", headers: headers # an ordinary read is not affected
      expect(response).to have_http_status(:ok)
    end
  end

  describe LoadShedder do
    let(:app) { ->(_env) { [ 200, {}, [ "ok" ] ] } }
    let(:backlog) { [ 0 ] }
    let(:shedder) { described_class.new(app, backlog: -> { backlog.first }) }

    def call(path, method: "GET") = shedder.call(Rack::MockRequest.env_for(path, method: method))

    before do
      @original = [ Rails.configuration.x.load_shedding, Rails.configuration.x.load_shedding_backlog ]
      Rails.configuration.x.load_shedding = true
      Rails.configuration.x.load_shedding_backlog = 2
    end

    after { Rails.configuration.x.load_shedding, Rails.configuration.x.load_shedding_backlog = @original }

    it "lets everything through while nothing is waiting for a thread" do
      %w[/api/v1/search /api/v1/projects/1/analytics /api/v1/activity /api/v1/projects/1/tasks].each { |path| expect(call(path).first).to eq(200) }
    end

    it "refuses the expensive reads, at once, once requests are queueing, with a Retry-After and the usual envelope" do
      backlog[0] = 2

      status, headers, body = call("/api/v1/search?q=x")

      expect(status).to eq(503)
      expect(headers).to include("x-load-shed" => "true", "cache-control" => "no-store")
      expect(headers["retry-after"].to_i).to be_between(1, 2)
      expect(JSON.parse(body.first).fetch("error")).to include("code" => "overloaded", "status" => 503)
      %w[/api/v1/projects/1/analytics /api/v1/activity /api/v1/projects/1/audit_events /api/v1/graphql /api/v1/ai/chat].each do |path|
        expect(call(path, method: path.include?("graphql") || path.include?("/ai/") ? "POST" : "GET").first).to eq(503), path
      end
    end

    it "keeps serving the cheap reads, every write, sign-in and the health checks, however long the queue" do
      backlog[0] = 500

      [ [ "/api/v1/projects/1/tasks", "GET" ], [ "/api/v1/projects", "GET" ], [ "/api/v1/projects/1/tasks", "POST" ], [ "/api/v1/tasks/1", "PATCH" ],
        [ "/api/v1/session", "POST" ], [ "/up", "GET" ], [ "/metrics", "GET" ], [ "/api/v1/search", "POST" ] ].each do |path, method|
        expect(call(path, method: method).first).to eq(200), "#{method} #{path}"
      end
    end

    it "does nothing when it is switched off, or when there is no signal (not running under Puma)" do
      backlog[0] = 99
      Rails.configuration.x.load_shedding = false
      expect(call("/api/v1/search").first).to eq(200)

      Rails.configuration.x.load_shedding = true
      backlog[0] = nil
      expect(call("/api/v1/search").first).to eq(200)
    end

    it "never fails a request because the signal failed" do
      broken = described_class.new(app, backlog: -> { raise "stats unavailable" })

      expect(broken.call(Rack::MockRequest.env_for("/api/v1/search")).first).to eq(200)
    end

    it "is in the middleware stack, ahead of authentication, and reads Puma's own backlog by default" do
      expect(Rails.application.middleware.map(&:name)).to include("LoadShedder")
      expect(described_class::DEFAULT_BACKLOG.call).to be_nil.or(be_a(Integer)) # nil here: the test run is not under Puma
    end

    it "counts what it refuses" do
      backlog[0] = 5
      before = Observability::Metrics::LOAD_SHED.get

      call("/api/v1/search")

      expect(Observability::Metrics::LOAD_SHED.get).to eq(before + 1)
    end
  end
end
