class OrganizationInvitationResource < ApplicationResource
  attributes :id, :email_address, :role, :status, :expires_at, :created_at

  one :invited_by, resource: UserSummaryResource
end
