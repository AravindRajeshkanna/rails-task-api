# Teams nest one level: "Engineering" can have "Backend" and "Frontend" in it, and a project granted to Engineering is reachable by the members of
# its sub-teams too (docs/decisions.md, ADR 53). Zero-downtime like the others: the key is added NOT VALID and validated next, and the index is
# partial because most teams have no parent. No ON DELETE action: a team with sub-teams cannot be deleted (Team validates that too, with a message).
class AddParentToTeams < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_reference :teams, :parent, null: true, index: false
    add_foreign_key :teams, :teams, column: :parent_id, validate: false
    add_index :teams, :parent_id, where: "parent_id IS NOT NULL", algorithm: :concurrently, name: "index_teams_on_parent_id"
  end
end
