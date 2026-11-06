require "aws-sdk-sqs"

module AuthService
  # Long-polls this service's queue (a subscription of the events topic that filters on `user.erased`) and deletes the identity of each person the Task API
  # says it has erased (ADR 79). Runs in a thread of the Puma process (lib/puma/plugin/auth_erasure_consumer.rb), as the Notification service's consumer does.
  #
  #   erased / unknown / ignored -> the message is deleted
  #   any failure                -> it is left on the queue; its visibility timeout grows with each attempt, and after maxReceiveCount SQS moves it to
  #                                 the dead-letter queue, whose alarm is how anyone finds out. Erasure cannot be undone and has nothing to compensate:
  #                                 the only direction is forward, until it has been done.
  class ErasureConsumer
    class InvalidEvent < StandardError; end

    BATCH = 10
    BASE_BACKOFF = 30 # seconds
    MAX_BACKOFF = 900
    TYPE = "user.erased".freeze
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    @last_poll = nil

    class << self
      def last_poll_age = @last_poll && Process.clock_gettime(Process::CLOCK_MONOTONIC) - @last_poll
      def beat! = @last_poll = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      def reset! = @last_poll = nil

      # The consumer thread ended with an error nobody rescued (the Puma plugin then stops the process, so that Kubernetes restarts it). Without this line
      # the pod would restart with nothing in its log to say why.
      def report_crash(error)
        Rails.logger.error({ event: "auth.erasure_consumer_crashed", error: error.class.name, message: error.message.truncate(300), backtrace: error.backtrace&.first(8) })
        Rails.error.report(error, handled: false, context: { consumer: "erasure" })
      end
    end

    def initialize(queue_url: Rails.configuration.x.erasure_queue_url, client: nil, wait_time: 20)
      raise ArgumentError, "AUTH_ERASURE_QUEUE_URL is not set" if queue_url.blank?

      @queue_url = queue_url
      @client = client || Aws::SQS::Client.new(region: ENV.fetch("AWS_REGION", "us-east-1"))
      @wait_time = wait_time
      @stopping = false
    end

    def run
      self.class.beat!
      Rails.logger.info({ event: "auth.erasure_consumer_started" })
      poll_once until @stopping
      Rails.logger.info({ event: "auth.erasure_consumer_stopped" })
    end

    def stop = @stopping = true

    def poll_once
      response = @client.receive_message(queue_url: @queue_url, max_number_of_messages: BATCH, wait_time_seconds: @wait_time, attribute_names: [ "ApproximateReceiveCount" ])
      response.messages.each { |message| process(message) }
      self.class.beat!
    rescue Aws::Errors::ServiceError, Seahorse::Client::NetworkingError => error
      Rails.error.report(error, handled: true, context: { consumer: "erasure-poll" })
      self.class.beat! # the loop is alive; AWS is the problem
      sleep(5) unless Rails.env.test?
    end

    def process(message)
      outcome = dispatch(parse(message.body))
      @client.delete_message(queue_url: @queue_url, receipt_handle: message.receipt_handle)
      Metrics::ERASURES.increment(labels: { outcome: outcome.to_s })
    rescue InvalidEvent, ActiveRecord::ActiveRecordError, JSON::ParserError => error
      retry_later(message, error)
    end

    private
      # :erased, :unknown (nothing here was theirs) or :ignored (an event type, or a person, this service has nothing to do with).
      def dispatch(envelope)
        raise InvalidEvent, "not a JSON object" unless envelope.is_a?(Hash)
        raise InvalidEvent, "unsupported specversion #{envelope['specversion'].inspect}" unless envelope["specversion"] == "1.0"
        return :ignored unless envelope["type"] == TYPE

        data = envelope["data"]
        raise InvalidEvent, "missing data" unless data.is_a?(Hash)

        subject = data["auth_subject"].presence
        legacy_id = data["user_id"]
        raise InvalidEvent, "auth_subject is not a uid" if subject && !UUID.match?(subject.to_s)
        raise InvalidEvent, "user_id is not an id" if legacy_id && !legacy_id.is_a?(Integer)

        Erasure.call(subject: subject, legacy_id: legacy_id)
      end

      # Raw delivery gives the CloudEvent itself; otherwise SNS wraps it in a notification.
      def parse(body)
        payload = JSON.parse(body)
        payload.is_a?(Hash) && payload["Type"] == "Notification" && payload["Message"] ? JSON.parse(payload["Message"]) : payload
      end

      def retry_later(message, error)
        attempts = message.attributes.to_h.fetch("ApproximateReceiveCount", "1").to_i
        delay = [ BASE_BACKOFF * (2**(attempts - 1)), MAX_BACKOFF ].min
        Rails.logger.warn({ event: "auth.erasure_failed", error: error.class.name.demodulize, message: error.message.truncate(200), attempt: attempts, retry_in: delay })
        Metrics::ERASURES.increment(labels: { outcome: "failed" })
        @client.change_message_visibility(queue_url: @queue_url, receipt_handle: message.receipt_handle, visibility_timeout: delay)
      end
  end
end
