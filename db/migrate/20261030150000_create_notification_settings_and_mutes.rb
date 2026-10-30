# Per-person say over what reaches them (docs/decisions.md, ADR 49). Settings are one row per person, created when they first change something
# (until then the defaults apply); mutes are one row per thing silenced: a kind everywhere, a project entirely, or one kind in one project.
class CreateNotificationSettingsAndMutes < ActiveRecord::Migration[8.1]
  def change
    create_table :notification_settings do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :digest, null: false, default: "off" # off: an email per event; daily: one summary a day instead
      t.integer :digest_hour, null: false, default: 8 # the hour of day, in time_zone, the summary is sent
      t.string :time_zone, null: false, default: "UTC"
      t.datetime :last_digest_at
      t.timestamps
    end
    add_check_constraint :notification_settings, "digest IN ('off', 'daily')", name: "notification_settings_digest_valid"
    add_check_constraint :notification_settings, "digest_hour BETWEEN 0 AND 23", name: "notification_settings_digest_hour_valid"

    create_table :notification_mutes do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :project, foreign_key: { on_delete: :cascade }
      t.string :kind
      t.datetime :created_at, null: false
    end
    # NULLS NOT DISTINCT: muting "everything in this project" twice is the same row, though kind is NULL both times.
    add_index :notification_mutes, %i[user_id project_id kind], unique: true, nulls_not_distinct: true, name: "index_notification_mutes_uniqueness"
    add_check_constraint :notification_mutes, "project_id IS NOT NULL OR kind IS NOT NULL", name: "notification_mutes_mutes_something"
    add_check_constraint :notification_mutes, "kind IS NULL OR kind IN ('task.assigned', 'task.due_soon', 'task.completed', 'comment.created')", name: "notification_mutes_kind_valid"
  end
end
