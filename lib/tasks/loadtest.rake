# A realistic data set for load testing and for reading query plans against more than a
# handful of rows. Use a database of its own, never one you care about:
#
#   DATABASE_URL=postgres:///task_api_loadtest bin/rails db:prepare
#   DATABASE_URL=postgres:///task_api_loadtest bin/rails loadtest:seed
#
# Bulk inserts skip callbacks, events and audit rows on purpose: this is about row counts.
# The first project is a "whale" with WHALE_TASKS tasks: real data is skewed, and one huge tenant
# is what exposes the queries that are fine at 1,000 rows and slow at 50,000.
# Writes tmp/loadtest/tokens.json (bearer tokens k6 reads; see loadtest/README.md).
# rubocop:disable Rails/SkipsModelValidations -- bulk inserts, deliberately
namespace :loadtest do
  desc "Fill the database with users, projects, memberships, tasks, comments (USERS, PROJECTS, TASKS_PER_PROJECT)"
  task seed: :environment do
    abort "Refusing to load-test seed in production." if Rails.env.production?
    abort "The database is not empty (#{User.count} users); use a fresh one." if User.exists?

    users_count = ENV.fetch("USERS", 500).to_i
    projects_count = ENV.fetch("PROJECTS", 100).to_i
    tasks_per_project = ENV.fetch("TASKS_PER_PROJECT", 1_000).to_i
    whale_tasks = ENV.fetch("WHALE_TASKS", 50_000).to_i
    random = Random.new(42) # same data every run, so results are comparable
    now = Time.current
    words = %w[design review deploy fix launch update migrate refactor write test plan audit document ship
               onboarding billing search invoice report dashboard export import cache index alert backup]

    # One precomputed digest: bcrypt is deliberately slow and every load-test user shares a password.
    digest = BCrypt::Password.create("loadtest-password", cost: 4)
    User.insert_all(Array.new(users_count) { |i|
      { name: "Load User #{i}", email_address: "load#{i}@example.test", password_digest: digest, created_at: now, updated_at: now }
    })
    user_ids = User.order(:id).ids

    Project.insert_all(Array.new(projects_count) { |i|
      { owner_id: user_ids[i % user_ids.size], name: "Load Project #{i}", description: "Synthetic project #{i}", created_at: now, updated_at: now }
    })
    project_ids = Project.order(:id).ids

    members = {}
    memberships = project_ids.flat_map do |project_id|
      owner = Project.find(project_id).owner_id
      team = ([ owner ] + user_ids.sample(random.rand(5..20), random: random)).uniq
      members[project_id] = team
      team.map { |user_id| { project_id: project_id, user_id: user_id, role: user_id == owner ? "admin" : "member", created_at: now, updated_at: now } }
    end
    Membership.insert_all(memberships)

    project_ids.each do |project_id|
      team = members[project_id]
      count = project_id == project_ids.first ? whale_tasks : tasks_per_project
      rows = Array.new(count) {
        status = random.rand < 0.4 ? 2 : random.rand(0..1)
        created = now - random.rand(0..365).days
        {
          project_id: project_id, creator_id: team.sample(random: random),
          assignee_id: random.rand < 0.2 ? nil : team.sample(random: random),
          title: Array.new(random.rand(3..6)) { words.sample(random: random) }.join(" ").capitalize,
          description: Array.new(random.rand(8..30)) { words.sample(random: random) }.join(" "),
          status: status, priority: random.rand(0..3),
          due_on: random.rand < 0.7 ? (Date.current + random.rand(-60..60)) : nil,
          completed_at: status == 2 ? created + random.rand(1..30).days : nil,
          created_at: created, updated_at: created
        }
      }
      rows.each_slice(5_000) { |batch| Task.insert_all(batch) }
      print "."
    end
    puts

    task_ids = Task.pluck(:id)
    Comment.insert_all(task_ids.sample(task_ids.size / 4, random: random).map { |task_id|
      { task_id: task_id, user_id: user_ids.sample(random: random), body: "Looks good to me", created_at: now, updated_at: now }
    })

    # Sessions for the first users, so k6 does not have to sign in (login is rate limited by design).
    tokens = user_ids.first(ENV.fetch("TOKENS", 50).to_i).map do |user_id|
      _session, token = Session.start_for!(User.find(user_id))
      token
    end
    FileUtils.mkdir_p(Rails.root.join("tmp/loadtest"))
    # user_ids.first owns the whale project, so the first token can read all of it.
    File.write(Rails.root.join("tmp/loadtest/tokens.json"), JSON.pretty_generate(tokens: tokens, whale_project_id: project_ids.first))

    ActiveRecord::Base.connection.execute("ANALYZE")
    puts "Seeded #{User.count} users, #{Project.count} projects, #{Membership.count} memberships, " \
         "#{Task.count} tasks, #{Comment.count} comments; #{tokens.size} tokens in tmp/loadtest/tokens.json"
  end
end
# rubocop:enable Rails/SkipsModelValidations
