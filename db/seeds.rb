# Demo data for local development. Safe to run repeatedly:  bin/rails db:seed
#
# Signs in as  demo@example.com / password123  (a throwaway account; never seeded in production).
abort "Refusing to seed demo accounts in production." if Rails.env.production?

def seed_user(name, email)
  User.find_or_create_by!(email_address: email) do |user|
    user.name = name
    user.password = "password123"
  end
end

demo = seed_user("Demo User", "demo@example.com")
teammate = seed_user("Taylor Teammate", "taylor@example.com")

project = demo.owned_projects.find_or_create_by!(name: "Website Relaunch") do |p|
  p.description = "Ship the new marketing site before the end of the quarter."
end
project.memberships.find_or_create_by!(user: teammate) { |m| m.role = :member }

if project.tasks.none?
  Current.session = Session.new(user: demo) # attribute audit events to the demo user

  [
    { title: "Design the landing page", status: :done, priority: :high, tag_names: %w[design] },
    { title: "Set up CI", status: :in_progress, priority: :medium, assignee: teammate, due_on: 3.days.from_now, tag_names: %w[devops] },
    { title: "Write launch announcement", status: :todo, priority: :low, due_on: 10.days.from_now, tag_names: %w[content] },
    { title: "Fix broken signup form", status: :todo, priority: :urgent, assignee: demo, due_on: 1.day.ago, tag_names: %w[bug frontend] }
  ].each do |attributes|
    project.tasks.build(creator: demo).tap { |task| task.assign_attributes(attributes) }.save!
  end

  project.tasks.find_by!(title: "Fix broken signup form").comments.create!(user: teammate, body: "Reproduced on Safari. Looking into it.")
  Current.reset
end

puts "Seeded #{User.count} users, #{Project.count} projects, #{Task.count} tasks."
