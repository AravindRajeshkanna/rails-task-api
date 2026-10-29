# Organization-level history (who joined, who was promoted, who invited whom) has no project, so
# audit events get an optional organization of their own. Zero-downtime like the others: the key is
# added NOT VALID and validated next; the index is partial because nearly every row belongs to a project.
class AddOrganizationToAuditEvents < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_reference :audit_events, :organization, null: true, index: false
    add_foreign_key :audit_events, :organizations, validate: false
    add_index :audit_events, %i[organization_id created_at], where: "organization_id IS NOT NULL",
      algorithm: :concurrently, name: "index_audit_events_on_organization_id_and_created_at"
  end
end
