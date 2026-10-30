class TeamMemberResource < ApplicationResource
  attributes :id, :created_at

  one :user, resource: UserSummaryResource
end
