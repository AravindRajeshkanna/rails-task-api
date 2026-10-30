# Which organization a record belongs to, found without a query where the policy has already loaded what it needs. Personal projects have none (nil),
# and so are limited as a person, not as an organization (ADR 62).
module Tenant
  module_function

  def organization_id_for(record)
    return if record.is_a?(Class) || record.nil?

    record.try(:organization_id) || record.try(:project)&.organization_id || record.try(:task)&.project&.organization_id ||
      record.try(:team)&.organization_id || record.try(:membership)&.try(:organization_id)
  end
end
