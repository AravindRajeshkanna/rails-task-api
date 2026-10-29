# Append-only history of changes to audited records (see Auditable).
# Marking records readonly makes Active Record raise on any update or destroy.
class AuditEvent < ApplicationRecord
  belongs_to :project, optional: true
  belongs_to :actor, class_name: "User", optional: true
  belongs_to :auditable, polymorphic: true

  def readonly? = persisted? || super
end
