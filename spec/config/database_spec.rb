require "rails_helper"

# `db:prepare` seeds a primary database it has just filled, and db/seeds.rb (demo accounts with a published password) aborts in production.
# So the first start against an empty production database exited 1 until production said not to seed: docker compose's migrate service
# did (found by running it); the Helm migration Job and Kamal's entrypoint run the same command.
RSpec.describe "database.yml seeding" do
  def primary(env) = ActiveRecord::Base.configurations.configs_for(env_name: env, name: "primary")

  it "does not seed in production, where db:prepare must not run db/seeds.rb" do
    expect(primary("production").seeds?).to be(false)
  end

  it "still seeds in development and test, where bin/setup and db:prepare are meant to load the demo data" do
    expect(primary("development").seeds?).to be(true)
    expect(primary("test").seeds?).to be(true)
  end

  it "leaves the guard in db/seeds.rb, which a hand-run `db:seed` in production must still meet" do
    expect(Rails.root.join("db/seeds.rb").read).to include('abort "Refusing to seed demo accounts in production." if Rails.env.production?')
  end
end
