require "aws-sdk-sqs"

module Notifications
  # Long-polls the SQS queue and hands each message to the Router.
  #
  #   handled / duplicate / ignored  -> the message is deleted
  #   any failure                    -> it is left on the queue; its visibility timeout is stretched with
  #                                     each attempt, and after maxReceiveCount SQS moves it to the DLQ
  class Consumer
    BATCH = 10
    BASE_BACKOFF = 30 # seconds
    MAX_BACKOFF = 900
    PRUNE_EVERY = 1.hour # this loop is the service's only long-lived process, so it is also where retention runs (idempotent, so replicas may overlap)

    def initialize(queue_url: Rails.configuration.x.queue_url, client: nil, router: Router.new, wait_time: 20)
      raise ArgumentError, "NOTIFICATIONS_QUEUE_URL is not set" if queue_url.blank?

      @queue_url = queue_url
      @client = client || Aws::SQS::Client.new(region: ENV.fetch("AWS_REGION", "us-east-1"))
      @router = router
      @wait_time = wait_time
      @stopping = false
    end

    def run
      Heartbeat.enable!
      Rails.logger.info({ event: "notification.consumer_started", queue_url: @queue_url })
      until @stopping
        prune_if_due
        poll_once
      end
      Rails.logger.info({ event: "notification.consumer_stopped" })
    end

    def stop = @stopping = true

    def poll_once
      response = @client.receive_message(
        queue_url: @queue_url, max_number_of_messages: BATCH, wait_time_seconds: @wait_time,
        attribute_names: [ "ApproximateReceiveCount" ]
      )
      response.messages.each { |message| process(message) }
      Heartbeat.beat!
    rescue Aws::Errors::ServiceError, Seahorse::Client::NetworkingError => error
      Rails.error.report(error, handled: true, context: { consumer: "sqs-poll" })
      Heartbeat.beat! # the loop is alive; AWS is the problem
      sleep(5) unless Rails.env.test?
    end

    def process(message)
      envelope = parse(message.body)
      outcome = @router.dispatch(envelope)
      @client.delete_message(queue_url: @queue_url, receipt_handle: message.receipt_handle)
      Metrics::PROCESSED.increment(labels: { type: envelope["type"].to_s, outcome: outcome.to_s })
    rescue InvalidEvent, DeliveryError, ActiveRecord::ActiveRecordError, JSON::ParserError => error
      retry_later(message, error)
    end

    def prune_if_due
      return if @pruned_at && @pruned_at > PRUNE_EVERY.ago

      @pruned_at = Time.current
      pruned = { deliveries: Delivery.prune!, processed_events: ProcessedEvent.prune! }
      Rails.logger.info({ event: "notification.pruned" }.merge(pruned)) if pruned.values.any?(&:positive?)
    rescue ActiveRecord::ActiveRecordError => error
      Rails.error.report(error, handled: true, context: { consumer: "retention" })
    end

    private
      # Raw delivery gives the CloudEvent itself; otherwise SNS wraps it in a notification.
      def parse(body)
        payload = JSON.parse(body)
        payload.is_a?(Hash) && payload["Type"] == "Notification" && payload["Message"] ? JSON.parse(payload["Message"]) : payload
      end

      def retry_later(message, error)
        attempts = message.attributes.to_h.fetch("ApproximateReceiveCount", "1").to_i
        delay = [ BASE_BACKOFF * (2**(attempts - 1)), MAX_BACKOFF ].min
        Rails.logger.warn({ event: "notification.failed", error: error.class.name.demodulize, message: error.message.truncate(200), attempt: attempts, retry_in: delay })
        Metrics::PROCESSED.increment(labels: { type: "unknown", outcome: "failed" })
        @client.change_message_visibility(queue_url: @queue_url, receipt_handle: message.receipt_handle, visibility_timeout: delay)
      end
  end
end
