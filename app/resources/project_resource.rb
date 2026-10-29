class ProjectResource < ApplicationResource
  attributes :id, :name, :description, :created_at, :updated_at

  # The viewer's role, selected by ProjectPolicy::Scope as +current_role+.
  attribute :role do |project|
    project.try(:current_role)
  end

  one :owner, resource: UserSummaryResource
end
