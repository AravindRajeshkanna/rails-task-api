module Demo
  # The data the public demo shows, rebuilt from nothing every night so whatever visitors did is gone by morning.
  #
  #   DEMO_MODE=true bin/rails demo:reset
  #
  # It EMPTIES THE DATABASE, so it refuses to run unless DEMO_MODE is on: a real instance can never be wiped by it. Records are
  # created through the models, as a person would, so the audit log, activity feed, search index, inbox and event outbox all fill in.
  # Everyone signs in with the password below, so the demo is public by design: nothing in it is private.
  class Dataset
    PASSWORD = "password123"
    TABLES_KEPT = %w[schema_migrations ar_internal_metadata].freeze

    def self.reset! = new.reset!

    def reset!
      raise "Refusing to wipe the database: DEMO_MODE is not on." unless Rails.configuration.x.demo_mode

      wipe
      seed
    end

    private
      def wipe
        connection = ActiveRecord::Base.connection
        tables = connection.tables - TABLES_KEPT
        connection.truncate_tables(*tables) # one statement over every table, so foreign keys do not get in the way
        tables.each { |table| connection.reset_pk_sequence!(table) } # ids start from 1 again
      end

      def seed
        people = create_people
        organization = create_organization(people)
        design, engineering = create_teams(organization, people)

        acting_as(people[:demo]) do
          website = create_project("Website Relaunch", "Ship the new marketing site before the end of the quarter.", people[:demo], organization)
          mobile = create_project("Mobile App", "Version 2 of the iOS and Android apps.", people[:taylor], organization)
          notes = create_project("Personal Notes", "Just for me.", people[:demo], nil)
          grant(website, design, :member)
          grant(website, engineering, :admin)
          grant(mobile, engineering, :admin)
          grant(mobile, design, :member)

          fill_website(website, people)
          fill_mobile(mobile, people)
          fill_notes(notes, people[:demo])
        end
        comment_on_tasks(people)
      end

      def create_people
        {
          demo: "Demo User", taylor: "Taylor Teammate", riley: "Riley Designer", jordan: "Jordan Writer", sam: "Sam Engineer"
        }.to_h do |key, name|
          [ key, User.create!(name: name, email_address: "#{key == :demo ? 'demo' : key}@example.com", password: PASSWORD) ]
        end
      end

      def create_organization(people)
        acting_as(people[:demo]) do
          Organizations::Create.call(user: people[:demo], attributes: { name: "Acme Studio" }).tap do |organization|
            { taylor: :admin, riley: :member, jordan: :member, sam: :member }.each do |key, role|
              organization.organization_memberships.create!(user: people[key], role: role)
            end
          end
        end
      end

      def create_teams(organization, people)
        acting_as(people[:demo]) do
          design = organization.teams.create!(name: "Design")
          engineering = organization.teams.create!(name: "Engineering")
          %i[riley jordan].each { |key| design.team_memberships.create!(user: people[key]) }
          %i[taylor sam].each { |key| engineering.team_memberships.create!(user: people[key]) }
          [ design, engineering ]
        end
      end

      def create_project(name, description, owner, organization)
        Project.create!(name: name, description: description, owner: owner, organization: organization)
      end

      def grant(project, team, role) = project.project_teams.create!(team: team, role: role)

      def fill_website(project, people)
        tasks(project, people[:demo], [
          [ "Design the landing page", :done, :high, :riley, -9, %w[design] ],
          [ "Write the launch announcement", :in_progress, :medium, :jordan, 3, %w[content] ],
          [ "Set up CI for the site", :done, :medium, :sam, -4, %w[devops] ],
          [ "Fix the broken signup form", :todo, :urgent, :sam, -1, %w[bug frontend] ],
          [ "Choose the new color palette", :done, :low, :riley, -12, %w[design] ],
          [ "Draft the pricing page copy", :in_progress, :high, :jordan, 1, %w[content] ],
          [ "Add analytics to the landing page", :todo, :medium, :taylor, 7, %w[frontend] ],
          [ "Migrate the blog to the new CMS", :todo, :low, nil, 21, %w[content devops] ],
          [ "Accessibility review", :todo, :high, :riley, 5, %w[design frontend] ],
          [ "Invoice template for the sales team", :in_progress, :medium, :taylor, 2, %w[content] ],
          [ "Set up the status page", :todo, :low, :sam, nil, %w[devops] ],
          [ "Optimize hero image loading", :done, :medium, :sam, -2, %w[frontend] ]
        ])
      end

      def fill_mobile(project, people)
        tasks(project, people[:taylor], [
          [ "Push notifications for assignments", :in_progress, :high, :sam, 4, %w[backend] ],
          [ "Offline mode for the task list", :todo, :urgent, :sam, 10, %w[backend frontend] ],
          [ "Dark mode", :todo, :low, :riley, 30, %w[design] ],
          [ "Crash on rotating the comment screen", :todo, :urgent, :taylor, -3, %w[bug] ],
          [ "App store screenshots", :done, :medium, :riley, -6, %w[design content] ],
          [ "Release notes for 2.0", :todo, :medium, :jordan, 8, %w[content] ]
        ])
      end

      def fill_notes(project, owner)
        tasks(project, owner, [
          [ "Renew the domain", :todo, :high, :demo, 6, %w[admin] ],
          [ "Read the Rails 8.1 release notes", :done, :low, :demo, -5, %w[learning] ],
          [ "Write the retrospective", :todo, :medium, nil, 14, %w[writing] ]
        ])
      end

      # Each row: title, status, priority, assignee key (or nil), due in N days (negative: overdue), tags.
      def tasks(project, creator, rows)
        rows.each_with_index do |(title, status, priority, assignee, due_in, tags), index|
          assignee_user = assignee && User.find_by!(email_address: "#{assignee}@example.com")
          project.tasks.build(creator: creator).tap do |task|
            task.assign_attributes(
              title: title, status: status, priority: priority, assignee: assignee_user, tag_names: tags,
              due_on: due_in && Date.current + due_in, created_at: (rows.size - index).days.ago,
              description: "#{title}. Part of #{project.name}: see the comments for the latest."
            )
            task.save!
          end
        end
      end

      def comment_on_tasks(people)
        {
          "Fix the broken signup form" => [ [ :sam, "Reproduced on Safari. Looking into it." ], [ :taylor, "Is it only the email field?" ] ],
          "Write the launch announcement" => [ [ :jordan, "First draft is in the shared doc." ], [ :riley, "Love it. Can we add a screenshot?" ] ],
          "Crash on rotating the comment screen" => [ [ :demo, "Seen in the beta feedback, three reports so far." ] ],
          "Accessibility review" => [ [ :taylor, "Let's include the contrast checks from the new palette." ] ]
        }.each do |title, comments|
          task = Task.find_by!(title: title)
          comments.each { |key, body| acting_as(people[key]) { task.comments.create!(user: people[key], body: body) } }
        end
      end

      # Runs the block as +user+, the way a request would, so audit events and notifications name the right person.
      def acting_as(user)
        previous = Current.session
        Current.session = Session.new(user: user)
        yield
      ensure
        Current.session = previous
      end
  end
end
