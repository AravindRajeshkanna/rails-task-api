class ValidateAuditEventsOrganizationForeignKey < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :audit_events, :organizations
  end
end
