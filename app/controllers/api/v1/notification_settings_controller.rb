module Api
  module V1
    # How the caller wants to hear about things beyond the inbox: a daily digest instead of an email per event, and when it arrives.
    # Until they change something the defaults apply (digest off), and are what GET returns.
    class NotificationSettingsController < BaseController
      # GET /notification_settings
      def show
        setting = NotificationSetting.for(current_user)
        authorize setting
        render_resource NotificationSettingResource, setting
      end

      # PATCH /notification_settings with any of { digest: "off"|"daily", digest_hour: 0..23, time_zone: "Europe/Paris" }
      def update
        setting = NotificationSetting.for(current_user)
        authorize setting
        setting.update!(params.permit(:digest, :digest_hour, :time_zone))
        render_resource NotificationSettingResource, setting
      end
    end
  end
end
