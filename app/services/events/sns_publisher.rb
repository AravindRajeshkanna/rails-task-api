require "aws-sdk-sns"

module Events
  # Publishes CloudEvents envelopes to the shared SNS topic (EVENTS_SNS_TOPIC_ARN). Delivery is
  # at-least-once, so consumers deduplicate on the envelope id. Credentials come from EKS Pod Identity.
  module SnsPublisher
    NotConfigured = Class.new(StandardError)
    # Throttling or a network blip: worth retrying with back-off.
    Retryable = Class.new(StandardError)

    RETRYABLE = [
      Aws::SNS::Errors::ThrottledException, Aws::SNS::Errors::InternalErrorException,
      Aws::SNS::Errors::KMSThrottlingException, Seahorse::Client::NetworkingError
    ].freeze

    class << self
      attr_writer :client

      def client
        @client ||= Aws::SNS::Client.new(region: ENV.fetch("AWS_REGION", "us-east-1"), retry_limit: 2, http_open_timeout: 3, http_read_timeout: 5)
      end

      def publish(envelope)
        envelope = envelope.with_indifferent_access
        topic = Rails.configuration.x.events.sns_topic_arn or raise NotConfigured, "EVENTS_SNS_TOPIC_ARN is not set"

        client.publish(topic_arn: topic, message: envelope.to_json, message_attributes: attributes(envelope))
      rescue *RETRYABLE => error
        raise Retryable, error.message
      end

      private
        # Subscriptions filter on these, so a consumer only receives the event types it asked for.
        def attributes(envelope)
          {
            "type" => { data_type: "String", string_value: envelope[:type] },
            "source" => { data_type: "String", string_value: envelope[:source] }
          }.tap do |attributes|
            attributes["project_id"] = { data_type: "Number", string_value: envelope[:projectid].to_s } if envelope[:projectid]
          end
        end
    end
  end
end
