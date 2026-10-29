class CreateSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :sessions do |t|
      t.references :user, null: false, foreign_key: true
      # Only the SHA-256 digest of the bearer token is stored, never the token itself.
      t.string :token_digest, null: false
      t.string :ip_address
      t.string :user_agent
      t.datetime :last_used_at
      t.datetime :expires_at, null: false

      t.timestamps
    end
    add_index :sessions, :token_digest, unique: true
    add_index :sessions, :expires_at
  end
end
