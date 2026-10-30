class ProjectResource < ApplicationResource
  sparse_fields preloads: { owner: :owner }

  attributes :id, :name, :description, :organization_id, :created_at, :updated_at

  # The viewer's role, selected by ProjectPolicy::Scope as +current_role+.
  attribute :role do |project|
    project.try(:current_role)
  end

  one :owner, resource: UserSummaryResource
end
