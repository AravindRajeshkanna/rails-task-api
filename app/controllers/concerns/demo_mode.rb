# The public demo: an instance anyone may sign in to, whose data is wiped and re-seeded every night (Demo::Dataset). Anything that
# sends mail, stores files, calls out to arbitrary addresses, spends AI budget or creates accounts is refused with 403 `demo_mode`, so the
# instance cannot be used as a mail relay, a file host or a webhook cannon. Everything else works normally, so the demo is the real API.
#
# Switched on by DEMO_MODE=true. Each response says so (`X-Demo-Mode: true`), for clients that want to show a banner.
module DemoMode
  extend ActiveSupport::Concern

  # controller_path#action. The list is explicit on purpose: a new route that sends mail or stores files is not in
  # it, and demo_mode_spec fails until someone decides.
  REFUSED = %w[
    api/v1/registrations#create
    api/v1/passwords#create api/v1/passwords#update
    api/v1/me#update api/v1/avatars#update
    api/v1/notification_settings#update
    api/v1/user_sessions#index api/v1/user_sessions#destroy
    api/v1/attachments#create
    api/v1/webhooks#create api/v1/webhooks#update
    api/v1/organization_invitations#create
    api/v1/invitation_acceptances#create
    api/v1/ai#suggest_priority api/v1/ai#suggest_tags api/v1/ai#suggest_assignee api/v1/ai#create_from_text api/v1/ai#chat
  ].freeze

  included do
    before_action :refuse_in_demo_mode
    before_action :announce_demo_mode
  end

  private
    def refuse_in_demo_mode
      return unless Rails.configuration.x.demo_mode && "#{controller_path}##{action_name}".in?(REFUSED)

      render_error :forbidden, "demo_mode", "This is not available in the public demo."
    end

    def announce_demo_mode
      response.headers["X-Demo-Mode"] = "true" if Rails.configuration.x.demo_mode
    end
end
