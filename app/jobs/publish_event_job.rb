# Publishes one domain event to SNS (see Events::SnsPublisher). Throttling retries with growing waits;
# a missing topic is a configuration problem, not something to retry.
class PublishEventJob < ApplicationJob
  queue_as :default

  retry_on Events::SnsPublisher::Retryable, wait: :polynomially_longer, attempts: 10
  discard_on Events::SnsPublisher::NotConfigured

  def perform(envelope)
    Events::SnsPublisher.publish(envelope)
  end
end
