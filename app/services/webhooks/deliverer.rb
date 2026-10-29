require "net/http"

module Webhooks
  # POSTs a WebhookDelivery to its receiver and records the outcome.
  #
  # Receivers verify authenticity by recomputing
  #   HMAC-SHA256(secret, "#{X-TaskApi-Timestamp}.#{raw body}")
  # and comparing it with X-TaskApi-Signature ("sha256=<hex>"); rejecting old
  # timestamps defeats replays.
  #
  # Non-2xx responses and network errors raise DeliveryFailed so the job retries.
  # A blocked address is permanent: it is recorded and never retried.
  class Deliverer
    class DeliveryFailed < StandardError; end

    TIMEOUT = 5 # seconds, for connect and for read

    def initialize(delivery)
      @delivery = delivery
      @webhook = delivery.webhook
    end

    def call
      uri = URI.parse(@webhook.url)
      address = UrlGuard.resolve!(uri.host)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      response = post(uri, address)
      duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round

      if response.is_a?(Net::HTTPSuccess)
        @delivery.update!(response_status: response.code.to_i, duration_ms: duration, error: nil, delivered_at: Time.current)
      else
        @delivery.update!(response_status: response.code.to_i, duration_ms: duration, error: "Receiver responded with HTTP #{response.code}")
        raise DeliveryFailed, "HTTP #{response.code}"
      end
    rescue UrlGuard::BlockedAddress => error
      @delivery.update!(error: "Blocked: #{error.message}")
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError => error
      @delivery.update!(error: "#{error.class}: #{error.message}".truncate(500))
      raise DeliveryFailed, error.message
    end

    private
      def post(uri, address)
        body = @delivery.payload.to_json
        timestamp = Time.current.to_i.to_s

        http = Net::HTTP.new(uri.host, uri.port)
        http.ipaddr = address # connect to the IP we vetted, not whatever DNS says now
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = TIMEOUT
        http.read_timeout = TIMEOUT

        request = Net::HTTP::Post.new(uri.request_uri, headers(body, timestamp))
        request.body = body
        http.request(request)
      end

      def headers(body, timestamp)
        {
          "Content-Type" => "application/json",
          "User-Agent" => "TaskApi-Webhooks/1.0",
          "X-TaskApi-Event" => @delivery.event,
          "X-TaskApi-Delivery" => @delivery.id.to_s,
          "X-TaskApi-Timestamp" => timestamp,
          "X-TaskApi-Signature" => "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', @webhook.secret, "#{timestamp}.#{body}")}"
        }
      end
  end
end
