require "prometheus/client"
require "prometheus/client/formats/text"

module ServiceKit
  # HTTP metrics shared by every service, fed from Rails.event's action_controller.request_completed, and
  # the /metrics endpoint. Service-specific metrics register on the same registry (ServiceKit::Metrics.registry).
  module Metrics
    BUCKETS = [ 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10 ].freeze

    class << self
      def registry = Prometheus::Client.registry

      def counter(name, docstring, labels = []) = registry.get(name) || registry.counter(name, docstring: docstring, labels: labels)
      def gauge(name, docstring, labels = []) = registry.get(name) || registry.gauge(name, docstring: docstring, labels: labels)

      def histogram(name, docstring, labels = [], buckets = BUCKETS)
        registry.get(name) || registry.histogram(name, docstring: docstring, labels: labels, buckets: buckets)
      end

      def http_requests = counter(:service_http_requests_total, "HTTP requests handled", %i[controller action status])
      def http_duration = histogram(:service_http_request_duration_seconds, "HTTP request duration", %i[controller action])
    end

    # Rails.event subscriber: turns request_completed into the HTTP metrics.
    class Subscriber
      def emit(event)
        return unless event[:name] == "action_controller.request_completed"

        payload = event[:payload]
        route = { controller: payload[:controller].to_s, action: payload[:action].to_s }
        Metrics.http_requests.increment(labels: route.merge(status: payload[:status].to_s))
        Metrics.http_duration.observe(payload[:duration_ms].to_f / 1000, labels: route)
      end
    end

    # Rack middleware serving GET /metrics ahead of the router. Refuses callers that are not on a private
    # network unless METRICS_TOKEN matches (the ingress never routes /metrics, this is the second lock).
    class Endpoint
      CONTENT_TYPE = "text/plain; version=0.0.4; charset=utf-8"

      def initialize(app, token: ENV["METRICS_TOKEN"], collectors: [])
        @app = app
        @token = token.to_s.empty? ? nil : token
        @collectors = collectors
      end

      def call(env)
        return @app.call(env) unless env["PATH_INFO"] == "/metrics" && env["REQUEST_METHOD"] == "GET"

        request = ActionDispatch::Request.new(env)
        return [ 403, { "content-type" => "text/plain" }, [ "forbidden\n" ] ] unless allowed?(request)

        @collectors.each(&:call)
        [ 200, { "content-type" => CONTENT_TYPE, "cache-control" => "no-store" }, [ Prometheus::Client::Formats::Text.marshal(Metrics.registry) ] ]
      end

      private
        def allowed?(request)
          if @token
            ActiveSupport::SecurityUtils.secure_compare(request.authorization.to_s.delete_prefix("Bearer "), @token)
          else
            !Rails.env.production? || private?(request.remote_ip)
          end
        end

        def private?(address)
          ip = IPAddr.new(address.to_s)
          ip.private? || ip.loopback? || ip.link_local?
        rescue IPAddr::InvalidAddressError
          false
        end
    end
  end
end
