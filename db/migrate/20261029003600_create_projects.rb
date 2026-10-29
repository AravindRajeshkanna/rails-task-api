class CreateProjects < ActiveRecord::Migration[8.1]
  def change
    create_table :projects do |t|
      t.references :owner, null: false, foreign_key: { to_table: :users }
      t.string :name, null: false
      t.text :description
      t.datetime :discarded_at

      t.timestamps
    end
    add_index :projects, :discarded_at

    create_table :memberships do |t|
      t.references :project, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :role, null: false, default: "member"

      t.timestamps
    end
    add_index :memberships, %i[project_id user_id], unique: true
  end
end
