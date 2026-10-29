class OrganizationResource < ApplicationResource
  attributes :id, :name, :created_at, :updated_at

  # The viewer's role, selected by OrganizationPolicy::Scope as +current_role+.
  attribute :role do |organization|
    organization.try(:current_role)
  end
end
