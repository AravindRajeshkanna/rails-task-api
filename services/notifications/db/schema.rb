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

ActiveRecord::Schema[8.1].define(version: 2026_10_29_170000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "deliveries", force: :cascade do |t|
    t.string "event_id", null: false
    t.string "event_type", null: false
    t.string "channel", null: false
    t.string "recipient"
    t.string "status", default: "sent", null: false
    t.datetime "created_at", null: false
    t.index [ "event_id" ], name: "index_deliveries_on_event_id"
    t.index [ "recipient", "created_at" ], name: "index_deliveries_on_recipient_and_created_at"
  end

  create_table "processed_events", force: :cascade do |t|
    t.string "event_id", null: false
    t.string "event_type", null: false
    t.datetime "created_at", null: false
    t.index [ "created_at" ], name: "index_processed_events_on_created_at"
    t.index [ "event_id" ], name: "index_processed_events_on_event_id", unique: true
  end
end
