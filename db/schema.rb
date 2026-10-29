# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_30_110000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_trgm"
  enable_extension "vector"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "ai_usages", force: :cascade do |t|
    t.bigint "user_id"
    t.bigint "project_id"
    t.string "feature", null: false
    t.string "model_id"
    t.string "outcome", default: "ok", null: false
    t.integer "input_tokens", default: 0, null: false
    t.integer "output_tokens", default: 0, null: false
    t.bigint "cost_micros", default: 0, null: false
    t.integer "latency_ms"
    t.datetime "created_at", null: false
    t.index ["project_id", "created_at"], name: "index_ai_usages_on_project_id_and_created_at"
    t.index ["project_id"], name: "index_ai_usages_on_project_id"
    t.index ["user_id", "created_at"], name: "index_ai_usages_on_user_id_and_created_at"
    t.index ["user_id"], name: "index_ai_usages_on_user_id"
    t.check_constraint "input_tokens >= 0 AND output_tokens >= 0 AND cost_micros >= 0", name: "ai_usages_counts_non_negative"
  end

  create_table "audit_events", force: :cascade do |t|
    t.bigint "project_id"
    t.bigint "actor_id"
    t.string "auditable_type", null: false
    t.bigint "auditable_id", null: false
    t.string "action", null: false
    t.jsonb "audit_changes", default: {}, null: false
    t.datetime "created_at", null: false
    t.bigint "organization_id"
    t.index ["actor_id"], name: "index_audit_events_on_actor_id"
    t.index ["auditable_type", "auditable_id"], name: "index_audit_events_on_auditable"
    t.index ["organization_id", "created_at"], name: "index_audit_events_on_organization_id_and_created_at", where: "(organization_id IS NOT NULL)"
    t.index ["project_id", "created_at"], name: "index_audit_events_on_project_id_and_created_at"
    t.index ["project_id"], name: "index_audit_events_on_project_id"
  end

  create_table "comments", force: :cascade do |t|
    t.bigint "task_id", null: false
    t.bigint "user_id", null: false
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["task_id"], name: "index_comments_on_task_id"
    t.index ["user_id"], name: "index_comments_on_user_id"
    t.check_constraint "char_length(btrim(body)) > 0", name: "comments_body_present"
  end

  create_table "memberships", force: :cascade do |t|
    t.bigint "project_id", null: false
    t.bigint "user_id", null: false
    t.string "role", default: "member", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "user_id"], name: "index_memberships_on_project_id_and_user_id", unique: true
    t.index ["project_id"], name: "index_memberships_on_project_id"
    t.index ["user_id"], name: "index_memberships_on_user_id"
    t.check_constraint "role::text = ANY (ARRAY['member'::character varying::text, 'admin'::character varying::text])", name: "memberships_role_valid"
  end

  create_table "notifications", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "project_id", null: false
    t.bigint "task_id", null: false
    t.bigint "actor_id"
    t.string "kind", null: false
    t.jsonb "data", default: {}, null: false
    t.string "dedupe_key"
    t.datetime "read_at"
    t.datetime "created_at", null: false
    t.index ["actor_id"], name: "index_notifications_on_actor_id"
    t.index ["project_id"], name: "index_notifications_on_project_id"
    t.index ["task_id"], name: "index_notifications_on_task_id"
    t.index ["user_id", "created_at", "id"], name: "index_notifications_on_user_id_and_created_at", order: { created_at: :desc, id: :desc }
    t.index ["user_id", "dedupe_key"], name: "index_notifications_on_user_id_and_dedupe_key", unique: true, where: "(dedupe_key IS NOT NULL)"
    t.index ["user_id"], name: "index_notifications_unread_on_user_id", where: "(read_at IS NULL)"
    t.check_constraint "kind::text = ANY (ARRAY['task.assigned'::character varying, 'task.due_soon'::character varying, 'task.completed'::character varying, 'comment.created'::character varying]::text[])", name: "notifications_kind_valid"
  end

  create_table "organization_invitations", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.bigint "invited_by_id"
    t.string "email_address", null: false
    t.string "role", default: "member", null: false
    t.datetime "expires_at", null: false
    t.datetime "accepted_at"
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_organization_invitations_on_email_address"
    t.index ["invited_by_id"], name: "index_organization_invitations_on_invited_by_id"
    t.index ["organization_id", "email_address"], name: "index_organization_invitations_pending", unique: true, where: "((accepted_at IS NULL) AND (revoked_at IS NULL))"
    t.index ["organization_id"], name: "index_organization_invitations_on_organization_id"
    t.check_constraint "char_length(btrim(email_address::text)) > 0", name: "organization_invitations_email_present"
    t.check_constraint "role::text = ANY (ARRAY['member'::character varying, 'admin'::character varying, 'owner'::character varying]::text[])", name: "organization_invitations_role_valid"
  end

  create_table "organization_memberships", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.bigint "user_id", null: false
    t.string "role", default: "member", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "user_id"], name: "index_organization_memberships_on_organization_id_and_user_id", unique: true
    t.index ["organization_id"], name: "index_organization_memberships_on_organization_id"
    t.index ["user_id"], name: "index_organization_memberships_on_user_id"
    t.check_constraint "role::text = ANY (ARRAY['member'::character varying, 'admin'::character varying, 'owner'::character varying]::text[])", name: "organization_memberships_role_valid"
  end

  create_table "organizations", force: :cascade do |t|
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.check_constraint "char_length(btrim(name::text)) > 0", name: "organizations_name_present"
  end

  create_table "project_teams", force: :cascade do |t|
    t.bigint "project_id", null: false
    t.bigint "team_id", null: false
    t.string "role", default: "member", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "team_id"], name: "index_project_teams_on_project_id_and_team_id", unique: true
    t.index ["project_id"], name: "index_project_teams_on_project_id"
    t.index ["team_id"], name: "index_project_teams_on_team_id"
    t.check_constraint "role::text = ANY (ARRAY['member'::character varying, 'admin'::character varying]::text[])", name: "project_teams_role_valid"
  end

  create_table "projects", force: :cascade do |t|
    t.bigint "owner_id", null: false
    t.string "name", null: false
    t.text "description"
    t.datetime "discarded_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "organization_id"
    t.index ["discarded_at"], name: "index_projects_on_discarded_at"
    t.index ["organization_id"], name: "index_projects_on_organization_id"
    t.index ["owner_id"], name: "index_projects_on_owner_id"
    t.check_constraint "char_length(btrim(name::text)) > 0", name: "projects_name_present"
  end

  create_table "sessions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "token_digest", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.datetime "last_used_at"
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_sessions_on_expires_at"
    t.index ["token_digest"], name: "index_sessions_on_token_digest", unique: true
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "taggings", force: :cascade do |t|
    t.bigint "task_id", null: false
    t.bigint "tag_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tag_id"], name: "index_taggings_on_tag_id"
    t.index ["task_id", "tag_id"], name: "index_taggings_on_task_id_and_tag_id", unique: true
    t.index ["task_id"], name: "index_taggings_on_task_id"
  end

  create_table "tags", force: :cascade do |t|
    t.bigint "project_id", null: false
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "name"], name: "index_tags_on_project_id_and_name", unique: true
    t.index ["project_id"], name: "index_tags_on_project_id"
    t.check_constraint "char_length(btrim(name::text)) > 0", name: "tags_name_present"
  end

  create_table "tasks", force: :cascade do |t|
    t.bigint "project_id", null: false
    t.bigint "creator_id", null: false
    t.bigint "assignee_id"
    t.string "title", null: false
    t.text "description"
    t.integer "status", default: 0, null: false
    t.integer "priority", default: 1, null: false
    t.date "due_on"
    t.datetime "completed_at"
    t.datetime "discarded_at"
    t.integer "lock_version", default: 0, null: false
    t.integer "comments_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.vector "embedding", limit: 1024
    t.string "embedding_digest"
    t.datetime "embedded_at"
    t.virtual "search_vector", type: :tsvector, as: "(setweight(to_tsvector('english'::regconfig, (COALESCE(title, ''::character varying))::text), 'A'::\"char\") || setweight(to_tsvector('english'::regconfig, COALESCE(description, ''::text)), 'B'::\"char\"))", stored: true
    t.index ["assignee_id"], name: "index_tasks_on_assignee_id"
    t.index ["creator_id"], name: "index_tasks_on_creator_id"
    t.index ["discarded_at"], name: "index_tasks_on_discarded_at"
    t.index ["embedding"], name: "index_tasks_on_embedding", opclass: :vector_cosine_ops, using: :hnsw
    t.index ["project_id", "created_at", "id"], name: "index_tasks_on_project_id_and_created_at_when_kept", order: { created_at: :desc, id: :desc }, where: "(discarded_at IS NULL)"
    t.index ["project_id", "due_on"], name: "index_tasks_on_project_id_and_due_on"
    t.index ["project_id", "status"], name: "index_tasks_on_project_id_and_status"
    t.index ["project_id"], name: "index_tasks_on_project_id"
    t.index ["search_vector"], name: "index_tasks_on_search_vector", using: :gin
    t.index ["title"], name: "index_tasks_on_title", opclass: :gin_trgm_ops, using: :gin
    t.check_constraint "char_length(btrim(title::text)) > 0", name: "tasks_title_present"
    t.check_constraint "comments_count >= 0 AND lock_version >= 0", name: "tasks_counters_non_negative"
    t.check_constraint "priority = ANY (ARRAY[0, 1, 2, 3])", name: "tasks_priority_valid"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2])", name: "tasks_status_valid"
  end

  create_table "team_memberships", force: :cascade do |t|
    t.bigint "team_id", null: false
    t.bigint "user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["team_id", "user_id"], name: "index_team_memberships_on_team_id_and_user_id", unique: true
    t.index ["team_id"], name: "index_team_memberships_on_team_id"
    t.index ["user_id"], name: "index_team_memberships_on_user_id"
  end

  create_table "teams", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index "organization_id, lower((name)::text)", name: "index_teams_on_organization_id_and_lower_name", unique: true
    t.index ["organization_id"], name: "index_teams_on_organization_id"
    t.check_constraint "char_length(btrim(name::text)) > 0", name: "teams_name_present"
  end

  create_table "users", force: :cascade do |t|
    t.string "name", null: false
    t.string "email_address", null: false
    t.string "password_digest"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "auth_subject"
    t.index ["auth_subject"], name: "index_users_on_auth_subject", unique: true, where: "(auth_subject IS NOT NULL)"
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
    t.check_constraint "char_length(btrim(email_address::text)) > 0", name: "users_email_present"
    t.check_constraint "char_length(btrim(name::text)) > 0", name: "users_name_present"
  end

  create_table "webhook_deliveries", force: :cascade do |t|
    t.bigint "webhook_id", null: false
    t.string "event", null: false
    t.jsonb "payload", default: {}, null: false
    t.integer "response_status"
    t.text "error"
    t.integer "duration_ms"
    t.datetime "delivered_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["webhook_id", "created_at"], name: "index_webhook_deliveries_on_webhook_id_and_created_at"
    t.index ["webhook_id"], name: "index_webhook_deliveries_on_webhook_id"
  end

  create_table "webhooks", force: :cascade do |t|
    t.bigint "project_id", null: false
    t.string "url", null: false
    t.text "secret", null: false
    t.string "events", default: [], null: false, array: true
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id"], name: "index_webhooks_on_project_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "ai_usages", "projects"
  add_foreign_key "ai_usages", "users"
  add_foreign_key "audit_events", "organizations"
  add_foreign_key "audit_events", "projects"
  add_foreign_key "audit_events", "users", column: "actor_id"
  add_foreign_key "comments", "tasks"
  add_foreign_key "comments", "users"
  add_foreign_key "memberships", "projects"
  add_foreign_key "memberships", "users"
  add_foreign_key "notifications", "projects", on_delete: :cascade
  add_foreign_key "notifications", "tasks", on_delete: :cascade
  add_foreign_key "notifications", "users", column: "actor_id", on_delete: :nullify
  add_foreign_key "notifications", "users", on_delete: :cascade
  add_foreign_key "organization_invitations", "organizations"
  add_foreign_key "organization_invitations", "users", column: "invited_by_id", on_delete: :nullify
  add_foreign_key "organization_memberships", "organizations"
  add_foreign_key "organization_memberships", "users"
  add_foreign_key "project_teams", "projects"
  add_foreign_key "project_teams", "teams"
  add_foreign_key "projects", "organizations"
  add_foreign_key "projects", "users", column: "owner_id"
  add_foreign_key "sessions", "users"
  add_foreign_key "taggings", "tags"
  add_foreign_key "taggings", "tasks"
  add_foreign_key "tags", "projects"
  add_foreign_key "tasks", "projects"
  add_foreign_key "tasks", "users", column: "assignee_id"
  add_foreign_key "tasks", "users", column: "creator_id"
  add_foreign_key "team_memberships", "teams"
  add_foreign_key "team_memberships", "users"
  add_foreign_key "teams", "organizations"
  add_foreign_key "webhook_deliveries", "webhooks"
  add_foreign_key "webhooks", "projects"
end
