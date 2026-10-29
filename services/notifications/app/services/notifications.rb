module Notifications
  # The event is malformed or lacks what its handler needs. Left on the queue; SQS moves it to the DLQ.
  class InvalidEvent < StandardError; end
  # A channel (SMTP, Slack) failed. Retried with backoff.
  class DeliveryError < StandardError; end
end
