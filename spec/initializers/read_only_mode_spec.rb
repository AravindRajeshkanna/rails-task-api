require "rails_helper"

# The cache in production is Solid Cache. The test environment uses a null store, so this builds a real Solid Cache in the test's own
# transaction (the table is created inside it and disappears with the rollback) and then makes the database refuse writes.
RSpec.describe ReadOnlyMode::CacheTolerance do
  let(:store) { SolidCache::Store.new(namespace: "read-only-spec", error_handler: ->(**) { }) }

  before do
    ActiveRecord::Migration.suppress_messages { load Rails.root.join("db/cache_schema.rb") }
    store.write("kept", "value")
  end

  def database_goes_read_only = ActiveRecord::Base.connection.execute("SET transaction_read_only = on")

  # Production runs each cache statement on its own (autocommit), so a refused write leaves nothing behind. The test's single transaction
  # would stay aborted after the first one, so each operation gets a savepoint to roll back to, which is what autocommit gives for free.
  def alone
    connection = ActiveRecord::Base.connection
    connection.execute("SAVEPOINT operation")
    yield
  ensure
    connection.execute("ROLLBACK TO SAVEPOINT operation")
  end

  it "is installed on Solid Cache" do
    expect(SolidCache::Store.ancestors.first(2)).to include(described_class)
  end

  it "works as usual while the database takes writes" do
    expect(store.read("kept")).to eq("value")
    expect(store.increment("counter", 1)).to eq(1)
  end

  it "skips writes and keeps serving reads while the database is read-only, instead of raising" do
    database_goes_read_only

    expect(alone { store.read("kept") }).to eq("value")
    expect(alone { store.read("never-written") }).to be_nil
    expect(alone { store.write("new", "value") }).to be_nil
    expect(alone { store.read("new") }).to be_nil
    expect(alone { store.increment("counter", 1) }).to be_nil
    expect(alone { store.fetch("computed") { "value" } }).to eq("value") # a miss computes and returns the value, and does not cache it
    expect(alone { store.delete("kept") }).to be(false)
  end

  it "still raises for any other database error" do
    allow(SolidCache::Entry).to receive(:upsert_all).and_raise(ActiveRecord::StatementInvalid, "PG::UndefinedTable: boom")

    expect { store.write("new", "value") }.to raise_error(ActiveRecord::StatementInvalid, /boom/)
  end
end
