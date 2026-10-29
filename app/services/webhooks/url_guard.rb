require "resolv"
require "ipaddr"

module Webhooks
  # SSRF protection for outgoing webhooks. Users choose the URL, so without this
  # a webhook could be pointed at http://169.254.169.254/ (cloud metadata),
  # localhost admin ports, or the internal network.
  #
  # The host is resolved once, checked, and the caller connects to *that* IP, so
  # DNS rebinding between check and connect is not possible.
  module UrlGuard
    class BlockedAddress < StandardError; end

    # Ranges Ruby's IPAddr predicates (private?, loopback?, link_local?) do not cover.
    EXTRA_BLOCKED = %w[
      0.0.0.0/8 100.64.0.0/10 192.0.0.0/24 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4 ::/128 ff00::/8
    ].map { |range| IPAddr.new(range) }.freeze

    module_function

    # Returns the IP address to connect to, or raises BlockedAddress.
    def resolve!(host)
      addresses = ip_literal?(host) ? [ host ] : Resolv.getaddresses(host)
      raise BlockedAddress, "#{host} does not resolve" if addresses.empty?

      unless Rails.configuration.x.webhooks.allow_private_networks
        blocked = addresses.find { |address| blocked?(IPAddr.new(address)) }
        raise BlockedAddress, "#{host} resolves to a non-public address" if blocked
      end

      addresses.first
    end

    def blocked?(ip)
      ip = ip.native if ip.ipv4_mapped? # ::ffff:127.0.0.1 is just 127.0.0.1
      ip.private? || ip.loopback? || ip.link_local? || EXTRA_BLOCKED.any? { |range| range.include?(ip) }
    end

    def ip_literal?(host)
      IPAddr.new(host)
      true
    rescue IPAddr::Error
      false
    end
  end
end
