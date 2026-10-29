class CreateUsersAndRefreshTokens < ActiveRecord::Migration[8.1]
  def change
    enable_extension "pgcrypto" unless extension_enabled?("pgcrypto")

    create_table :users do |t|
      t.uuid :uid, null: false, default: -> { "gen_random_uuid()" } # the JWT subject
      t.string :name, null: false
      t.string :email_address, null: false
      t.string :password_digest, null: false
      t.bigint :legacy_id # the user's id in the monolith before the migration (see users:import)
      t.timestamps
    end
    add_index :users, :uid, unique: true
    add_index :users, :email_address, unique: true
    add_index :users, :legacy_id, unique: true, where: "legacy_id IS NOT NULL"

    create_table :refresh_tokens do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :token_digest, null: false
      t.uuid :family_id, null: false # every rotation of one login shares a family
      t.datetime :expires_at, null: false
      t.datetime :revoked_at
      t.string :ip_address
      t.string :user_agent
      t.datetime :created_at, null: false
    end
    add_index :refresh_tokens, :token_digest, unique: true
    add_index :refresh_tokens, :family_id
  end
end
