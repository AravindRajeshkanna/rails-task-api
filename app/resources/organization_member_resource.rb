class OrganizationMemberResource < ApplicationResource
  attributes :id, :role, :created_at

  one :user, resource: UserSummaryResource
end
