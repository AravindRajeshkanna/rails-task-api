require "rails_helper"

RSpec.describe "Read-only mode" do
  let(:user) { create(:user) }
  let!(:project) { create(:project, owner: user) }
  let!(:task) { create(:task, project: project) }
  let(:headers) { auth_headers(user) }

  def read_only(on)
    original = Rails.configuration.x.read_only
    Rails.configuration.x.read_only = on
    yield
  ensure
    Rails.configuration.x.read_only = original
  end

  # What a replica does: the transaction (here the test's own) refuses every write from now on. Postgres only lets a
  # transaction become read-only, never read-write again, so everything the example needs is created before this is called.
  def database_goes_read_only
    ActiveRecord::Base.connection.execute("SET transaction_read_only = on")
  end

  def expect_refused(source)
    expect(response).to have_http_status(:service_unavailable)
    expect(error).to include("status" => 503, "code" => "read_only", "request_id" => response.headers["X-Request-Id"])
    expect(response.headers).to include("Retry-After" => ReadOnlyMode::RETRY_AFTER.to_s, "Cache-Control" => "no-store")
    expect(response.media_type).to eq("application/json")
    expect(Observability::Metrics::READ_ONLY_REFUSALS.get(labels: { source: source })).to be > 0
  end

  describe "with READ_ONLY=true (writes drained before a planned switchover)" do
    it "serves reads normally" do
      read_only(true) do
        api :get, "/api/v1/projects/#{project.id}/tasks", as: user

        expect(response).to have_http_status(:ok)
        expect(data.pluck("id")).to eq([ task.id ])
      end
    end

    it "refuses writes in the usual envelope, with Retry-After, and changes nothing" do
      read_only(true) do
        expect { api :post, "/api/v1/projects/#{project.id}/tasks", { title: "Late" }, as: user }.not_to change(Task, :count)
        expect_refused("switch")

        expect { api :patch, "/api/v1/tasks/#{task.id}", { title: "Changed" }, as: user }.not_to(change { task.reload.title })
        expect_refused("switch")
      end
    end

    it "does not stop a signed-in read over the usage timestamp" do
      session = Session.find_by!(token_digest: Session.digest(headers["Authorization"].split.last))
      session.update_column(:last_used_at, 1.day.ago)

      read_only(true) do
        get "/api/v1/projects", headers: headers
      end

      expect(response).to have_http_status(:ok)
      expect(session.reload.last_used_at).to be < 1.hour.ago
    end

    it "keeps read-only POSTs working: GraphQL queries are POSTs" do
      read_only(true) do
        post "/api/v1/graphql", params: { query: "{ me { id } }" }.to_json, headers: headers.merge("Content-Type" => "application/json")

        expect(response).to have_http_status(:ok)
        expect(json.dig("data", "me", "id")).to be_present
      end
    end
  end

  describe "with a database that is a read-only replica" do
    it "serves reads, including a stale session's usage stamp, and answers writes 503 instead of 500" do
      session = Session.find_by!(token_digest: Session.digest(headers["Authorization"].split.last))
      session.update_column(:last_used_at, 1.day.ago)
      database_goes_read_only

      get "/api/v1/projects/#{project.id}/tasks", headers: headers
      expect(response).to have_http_status(:ok)
      expect(json["data"].pluck("id")).to eq([ task.id ])

      post "/api/v1/projects/#{project.id}/tasks", params: { title: "Late" }.to_json, headers: headers.merge("Content-Type" => "application/json")
      expect_refused("database")
    end
  end

  describe ReadOnlyMode::Middleware do
    def call = described_class.new(->(_env) { yield }).call("REQUEST_METHOD" => "POST")

    it "answers only the database's refusal to write, and lets every other error through" do
      expect(call { raise ActiveRecord::ReadOnlyError, "prevented" }.first).to eq(503)
      expect { call { raise ActiveRecord::StatementInvalid, "PG::UndefinedTable" } }.to raise_error(ActiveRecord::StatementInvalid)
      expect { call { raise ActiveRecord::RecordNotFound } }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe ReadOnlyMode do
    def statement_invalid(cause)
      ActiveRecord::StatementInvalid.new("boom").tap { |error| error.define_singleton_method(:cause) { cause } }
    end

    it "recognises the two ways a write is refused, and nothing else" do
      expect(described_class.error?(ActiveRecord::ReadOnlyError.new("prevented"))).to be(true)
      expect(described_class.error?(statement_invalid(PG::ReadOnlySqlTransaction.new("cannot execute INSERT in a read-only transaction")))).to be(true)

      expect(described_class.error?(statement_invalid(PG::UndefinedTable.new("nope")))).to be(false)
      expect(described_class.error?(ActiveRecord::RecordNotFound.new("nope"))).to be(false)
      expect(described_class.error?(RuntimeError.new("nope"))).to be(false)
    end
  end
end
