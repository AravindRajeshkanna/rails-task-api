module AuthService
  # Publishes CloudEvents to the shared SNS topic (consumed by the Notification service). Without
  # EVENTS_SNS_TOPIC_ARN (local development) the event is only logged. A failure to publish never fails the
  # request: for a password reset the user can simply ask again. It is not retried when the topic comes back (the SDK retries only within the call), and it is
  # logged: nothing subscribes to Rails.error here, so without that line a reset email that never came left no trace (measured on docker compose, roadmap 13).
  module Events
    class << self
      attr_writer :client

      def client = @client ||= Aws::SNS::Client.new(region: ENV.fetch("AWS_REGION", "us-east-1"), retry_limit: 2, http_open_timeout: 3, http_read_timeout: 5)

      def publish(type, data)
        envelope = {
          specversion: "1.0", id: SecureRandom.uuid, source: "auth-service", type: type, time: Time.current.utc.iso8601(3),
          datacontenttype: "application/json", data: data
        }
        topic = Rails.configuration.x.events.sns_topic_arn

        if topic.present?
          client.publish(topic_arn: topic, message: envelope.to_json, message_attributes: {
            "type" => { data_type: "String", string_value: type }, "source" => { data_type: "String", string_value: "auth-service" }
          })
        else
          Rails.logger.info({ event: "auth.event_not_published", type: type, reason: "EVENTS_SNS_TOPIC_ARN is not set" })
        end
        envelope
      rescue Aws::Errors::ServiceError, Seahorse::Client::NetworkingError => error
        Rails.error.report(error, handled: true, context: { event: type })
        # The type and the error only: the event holds an address and a reset link.
        Rails.logger.warn({ event: "auth.event_publish_failed", type: type, error: error.class.name, message: error.message })
        nil
      end
    end
  end
end
