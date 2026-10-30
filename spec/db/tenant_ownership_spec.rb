require "rails_helper"

# Who owns every row, written down and checked (docs/architecture/data-lifecycle.md). Splitting the database by tenant, or finding all of a
# tenant's data to export or delete it, starts from this map; it fails when a table is added without anyone deciding where it belongs.
#
#   organization  rows belong to one organization (the tenant)
#   project       rows belong to one project, and so to the project's organization (none, for a personal project)
#   user          rows belong to one person and follow them across organizations
#   platform      belongs to no tenant (storage metadata, the outbox)
#
# The second element is the column that leads from the row toward its owner (a foreign key), nil for the root itself.
RSpec.describe "Tenant ownership map" do
  let(:ownership) do
    {
      "organizations" => [ :organization, nil ],
      "organization_memberships" => [ :organization, "organization_id" ],
      "organization_invitations" => [ :organization, "organization_id" ],
      "teams" => [ :organization, "organization_id" ],
      "team_memberships" => [ :organization, "team_id" ],
      "projects" => [ :organization, "organization_id" ], # nullable: a personal project has no organization
      "project_teams" => [ :project, "project_id" ],
      "memberships" => [ :project, "project_id" ],
      "tasks" => [ :project, "project_id" ],
      "comments" => [ :project, "task_id" ],
      "tags" => [ :project, "project_id" ],
      "taggings" => [ :project, "task_id" ],
      "webhooks" => [ :project, "project_id" ],
      "webhook_deliveries" => [ :project, "webhook_id" ],
      "notifications" => [ :project, "project_id" ], # also one user's inbox: the user is the reader, the project is the owner
      "ai_usages" => [ :project, "project_id" ], # nullable
      "audit_events" => [ :project, "project_id" ], # nullable: organization-level events have organization_id instead
      "users" => [ :user, nil ],
      "sessions" => [ :user, "user_id" ],
      "notification_settings" => [ :user, "user_id" ],
      "notification_mutes" => [ :user, "user_id" ],
      "idempotency_keys" => [ :user, "user_id" ],
      "active_storage_attachments" => [ :project, nil ], # polymorphic (a task's file or a user's avatar): the owner is the record it names
      "active_storage_blobs" => [ :platform, nil ],
      "active_storage_variant_records" => [ :platform, nil ],
      "outbox_events" => [ :platform, nil ]
    }
  end

  let(:connection) { ActiveRecord::Base.connection }

  it "classifies every table, so a new one cannot arrive without someone deciding who owns its rows" do
    expect(connection.tables - %w[schema_migrations ar_internal_metadata]).to match_array(ownership.keys)
  end

  it "names, for each table that reaches its owner through a column, a real column with a foreign key behind it" do
    ownership.each do |table, (_owner, column)|
      next unless column

      expect(connection.foreign_keys(table).map(&:column)).to include(column), "#{table}.#{column} is not a foreign key"
    end
  end
end
