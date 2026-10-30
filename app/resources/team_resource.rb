class TeamResource < ApplicationResource
  attributes :id, :organization_id, :parent_id, :name, :created_at, :updated_at

  # Counted by the controller's query (see TeamsController#with_member_counts); nil if it was not selected.
  attribute :members_count do |team|
    team.try(:members_count)
  end
end
