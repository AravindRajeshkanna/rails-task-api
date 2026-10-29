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

ActiveRecord::Schema[8.1].define(version: 2026_10_29_160000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "refresh_tokens", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "token_digest", null: false
    t.uuid "family_id", null: false
    t.datetime "expires_at", null: false
    t.datetime "revoked_at"
    t.string "ip_address"
    t.string "user_agent"
    t.datetime "created_at", null: false
    t.index [ "family_id" ], name: "index_refresh_tokens_on_family_id"
    t.index [ "token_digest" ], name: "index_refresh_tokens_on_token_digest", unique: true
    t.index [ "user_id" ], name: "index_refresh_tokens_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.uuid "uid", default: -> { "gen_random_uuid()" }, null: false
    t.string "name", null: false
    t.string "email_address", null: false
    t.string "password_digest", null: false
    t.bigint "legacy_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index [ "email_address" ], name: "index_users_on_email_address", unique: true
    t.index [ "legacy_id" ], name: "index_users_on_legacy_id", unique: true, where: "(legacy_id IS NOT NULL)"
    t.index [ "uid" ], name: "index_users_on_uid", unique: true
  end

  add_foreign_key "refresh_tokens", "users", on_delete: :cascade
end
