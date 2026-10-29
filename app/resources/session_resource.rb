# Response to sign-up / sign-in. The plaintext token is only available here.
#   SessionResource.new(session, params: { token: token })
class SessionResource < ApplicationResource
  attribute(:token) { params.fetch(:token) }
  attributes :expires_at
  one :user, resource: UserResource
end
