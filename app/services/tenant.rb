# Which organization a record belongs to, found without a query where the policy has already loaded what it needs. Personal projects have none (nil),
# and so are limited as a person, not as an organization (ADR 62).
module Tenant
  # The ways a record can reach its organization, shortest first: itself, through its project, through its task's project, through its team.
  PATHS = [ %i[organization_id], %i[project organization_id], %i[task project organization_id], %i[team organization_id] ].freeze

  module_function

  def organization_id_for(record)
    return if record.nil? || record.is_a?(Class)

    PATHS.each do |path|
      found = path.reduce(record) { |holder, step| holder&.try(step) }
      return found if found
    end
    nil
  end
end
