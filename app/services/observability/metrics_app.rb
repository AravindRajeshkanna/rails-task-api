module Observability
  # GET /metrics in the Prometheus text format. Not part of the public API: the ingress only routes
  # /api, /up and /api-docs, and this app additionally refuses callers that are neither on a private
  # network (Prometheus scraping the pod directly) nor carrying METRICS_TOKEN.
  class MetricsApp
    CONTENT_TYPE = "text/plain; version=0.0.4; charset=utf-8"

    def initialize(token: ENV["METRICS_TOKEN"])
      @token = token.presence
    end

    def call(env)
      request = ActionDispatch::Request.new(env)
      return forbidden unless allowed?(request)

      Collector.refresh!
      [ 200, { "content-type" => CONTENT_TYPE, "cache-control" => "no-store" }, [ Prometheus::Client::Formats::Text.marshal(Metrics::REGISTRY) ] ]
    end

    private
      def allowed?(request)
        if @token
          provided = request.authorization.to_s.delete_prefix("Bearer ")
          ActiveSupport::SecurityUtils.secure_compare(provided, @token)
        else
          !Rails.env.production? || private_address?(request.remote_ip)
        end
      end

      def private_address?(address)
        ip = IPAddr.new(address.to_s)
        ip.private? || ip.loopback? || ip.link_local?
      rescue IPAddr::InvalidAddressError
        false
      end

      def forbidden = [ 403, { "content-type" => "text/plain" }, [ "forbidden\n" ] ]
  end
end
