# The in-app inbox: one row per notification per recipient, with read state. Rows disappear with the
# user, project or task they are about (the foreign keys cascade), so a hard purge of a deleted
# project cleans the inbox without a callback. `data` is a snapshot (task title, project name, a
# comment excerpt), so listing never joins and an old notification still reads sensibly.
class CreateNotifications < ActiveRecord::Migration[8.1]
  def change
    create_table :notifications do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :task, null: false, foreign_key: { on_delete: :cascade }
      t.references :actor, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :kind, null: false
      t.jsonb :data, null: false, default: {}
      # A key that makes a notification happen once however often the event repeats (a reminder job that is re-run).
      t.string :dedupe_key
      t.datetime :read_at
      t.datetime :created_at, null: false
    end
    add_index :notifications, %i[user_id created_at id], order: { created_at: :desc, id: :desc }, name: "index_notifications_on_user_id_and_created_at"
    add_index :notifications, :user_id, where: "read_at IS NULL", name: "index_notifications_unread_on_user_id"
    add_index :notifications, %i[user_id dedupe_key], unique: true, where: "dedupe_key IS NOT NULL", name: "index_notifications_on_user_id_and_dedupe_key"
    add_check_constraint :notifications, "kind IN ('task.assigned', 'task.due_soon', 'task.completed', 'comment.created')", name: "notifications_kind_valid"
  end
end
