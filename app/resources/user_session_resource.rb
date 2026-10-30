# One sign-in of the caller's, as listed by GET /sessions. Never the token or its digest: those cannot be recovered, by design.
class UserSessionResource < ApplicationResource
  attributes :id, :ip_address, :user_agent, :created_at, :last_used_at, :expires_at

  attribute(:current) { |session| session.id == params[:current_id] }
end
