class CreateTasks < ActiveRecord::Migration[8.1]
  def change
    # Trigram index makes ILIKE '%term%' search on titles index-assisted.
    enable_extension "pg_trgm"

    create_table :tasks do |t|
      t.references :project, null: false, foreign_key: true
      t.references :creator, null: false, foreign_key: { to_table: :users }
      t.references :assignee, foreign_key: { to_table: :users }
      t.string :title, null: false
      t.text :description
      # Integer-backed enums (see Task) so ORDER BY follows severity / workflow order.
      t.integer :status, null: false, default: 0
      t.integer :priority, null: false, default: 1
      t.date :due_on
      t.datetime :completed_at
      t.datetime :discarded_at
      t.integer :lock_version, null: false, default: 0
      t.integer :comments_count, null: false, default: 0

      t.timestamps
    end
    add_index :tasks, %i[project_id status]
    add_index :tasks, %i[project_id due_on]
    add_index :tasks, :discarded_at
    add_index :tasks, :title, using: :gin, opclass: :gin_trgm_ops

    create_table :comments do |t|
      t.references :task, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.text :body, null: false

      t.timestamps
    end

    create_table :tags do |t|
      t.references :project, null: false, foreign_key: true
      t.string :name, null: false

      t.timestamps
    end
    add_index :tags, %i[project_id name], unique: true

    create_table :taggings do |t|
      t.references :task, null: false, foreign_key: true
      t.references :tag, null: false, foreign_key: true

      t.timestamps
    end
    add_index :taggings, %i[task_id tag_id], unique: true
  end
end
