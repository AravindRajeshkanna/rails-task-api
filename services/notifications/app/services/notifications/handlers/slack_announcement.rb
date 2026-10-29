module Notifications
  module Handlers
    # Posts selected events to a Slack incoming webhook (SLACK_WEBHOOK_URL, events in SLACK_EVENTS).
    class SlackAnnouncement < Base
      def call
        return if Rails.configuration.x.slack_webhook_url.blank?
        return unless Rails.configuration.x.slack_events.include?(envelope["type"])

        Slack.post(text)
        record("slack", "webhook")
      end

      private
        def text
          title = data["title"].to_s.squish.truncate(150)
          "Task completed: #{title} (project #{envelope['projectid']})"
        end
    end
  end
end
