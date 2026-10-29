module Api
  module V1
    # POST /invitations/accept: redeem the token from an invitation email, as the address it was sent to.
    # Authorization is possession of the token plus being that address, checked in the command; every
    # failure is the same 404 (see Organizations::AcceptInvitation).
    class InvitationAcceptancesController < BaseController
      rate_limit to: 20, within: 10.minutes, by: -> { current_user.id },
                 with: -> { render_error :too_many_requests, "rate_limited", "Too many attempts. Try again later." }

      def create
        skip_authorization
        membership = Organizations::AcceptInvitation.call(user: current_user, token: params.require(:token))
        organization = policy_scope(Organization).find(membership.organization_id)
        render_resource OrganizationResource, organization, status: :created
      end
    end
  end
end
