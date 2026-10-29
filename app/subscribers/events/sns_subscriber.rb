module Events
  # Hands domain events to PublishEventJob, so publishing to SNS happens off the request path, with retries.
  # The envelope (and its id) is built here, once: a retry resends the same event, which consumers can
  # recognise and ignore.
  class SnsSubscriber < Subscriber
    private
      def handle(event)
        envelope = CloudEvent.build(event)
        PublishEventJob.perform_later(envelope) if envelope
      end
  end
end
