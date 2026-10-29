class MembershipResource < ApplicationResource
  attributes :id, :project_id, :role, :created_at

  one :user, resource: UserSummaryResource
end
