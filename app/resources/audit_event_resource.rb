class AuditEventResource < ApplicationResource
  attributes :id, :action, :auditable_type, :auditable_id, :created_at

  attribute(:changes) { |event| event.audit_changes }

  one :actor, resource: UserSummaryResource
end
