# Deletes organization invitations 90 days after they concluded (accepted, revoked or expired), with the address on them. An invitation names
# an email address whether or not anyone with it ever signed up, so the list of who was once invited somewhere is not kept for ever.
class PurgeInvitationsJob < ApplicationJob
  queue_as :low

  def perform
    OrganizationInvitation.concluded_before(OrganizationInvitation::RETENTION.ago).in_batches(of: 1_000) { |batch| OrganizationInvitation.forget!(batch) }
  end
end
