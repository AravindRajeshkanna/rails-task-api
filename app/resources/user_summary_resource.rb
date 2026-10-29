# Minimal user reference embedded in other payloads. Deliberately omits the email address.
class UserSummaryResource < ApplicationResource
  attributes :id, :name
end
