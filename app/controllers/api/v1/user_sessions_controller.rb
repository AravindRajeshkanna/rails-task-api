module Api
  module V1
    # GET /sessions and DELETE /sessions/:id: where the caller is signed in, and ending any of those (a lost phone, a forgotten laptop).
    # With AUTH_MODE=jwt sign-ins belong to the Auth service, which has this: the routes are not drawn at all (see config/routes.rb).
    class UserSessionsController < BaseController
      def index
        authorize Session
        records, meta = paginate(policy_scope(Session).order(last_used_at: :desc, id: :desc))
        render_resource UserSessionResource, records, meta: meta, params: { current_id: Current.session&.id }
      end

      def destroy
        session = policy_scope(Session).find(params[:id])
        authorize session
        session.destroy!
        Rails.event.notify("session.revoked", session_id: session.id, current: session.id == Current.session&.id)
        head :no_content
      end
    end
  end
end
