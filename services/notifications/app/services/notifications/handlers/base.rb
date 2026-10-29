module Notifications
  module Handlers
    class Base
      EMAIL = URI::MailTo::EMAIL_REGEXP

      def initialize(envelope)
        @envelope = envelope
        @data = envelope.fetch("data")
      end

      private
        attr_reader :envelope, :data

        def recipient
          address = data.dig("recipient", "email_address").to_s
          raise InvalidEvent, "recipient has no valid email address" unless address.match?(EMAIL)

          address
        end

        def record(channel, recipient)
          Delivery.create!(event_id: envelope["id"], event_type: envelope["type"], channel: channel, recipient: recipient)
          Metrics::DELIVERIES.increment(labels: { channel: channel })
        end

        # Validates the recipient before anything is sent, then delivers and records.
        def deliver(mailer_method)
          address = recipient
          NotificationMailer.public_send(mailer_method, data).deliver_now
          record("email", address)
        rescue Net::SMTPError, IOError, SystemCallError, Timeout::Error, SocketError => error
          raise DeliveryError, "SMTP failed: #{error.class}"
        end
    end
  end
end
