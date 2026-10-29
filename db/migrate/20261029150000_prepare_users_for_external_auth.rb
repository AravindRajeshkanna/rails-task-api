class PrepareUsersForExternalAuth < ActiveRecord::Migration[8.1]
  # Step one of extracting authentication (see docs/architecture/microservices.md): the Auth service owns
  # credentials, so a local user can exist without a password. users stays here as a projection keyed by
  # the Auth service's subject id, which the foreign keys (projects, tasks, comments, ...) still point at.
  def change
    add_column :users, :auth_subject, :string
    add_index :users, :auth_subject, unique: true, where: "auth_subject IS NOT NULL"
    change_column_null :users, :password_digest, true
  end
end
