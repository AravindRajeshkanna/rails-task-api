# A project optionally belongs to an organization (personal projects have none). Done the
# zero-downtime way: the index is built concurrently and the foreign key is added NOT VALID, so
# neither blocks writes to projects; the next migration validates the key.
class AddOrganizationToProjects < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_reference :projects, :organization, null: true, index: { algorithm: :concurrently }
    add_foreign_key :projects, :organizations, validate: false
  end
end
