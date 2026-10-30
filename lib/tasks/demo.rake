namespace :demo do
  desc "EMPTY the database and load the demo data (only when DEMO_MODE=true; see docs/demo.md)"
  task reset: :environment do
    Demo::Dataset.reset!
    puts "Demo data loaded: #{User.count} people, #{Project.count} projects, #{Task.count} tasks. Sign in as demo@example.com / #{Demo::Dataset::PASSWORD}."
  end
end
