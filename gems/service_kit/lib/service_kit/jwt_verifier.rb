require "jwt"
require "json"
require "net/http"

module ServiceKit
  # Verifies the RS256 access tokens issued by the Auth service, locally: no call per request. Public keys
  # come from the Auth service's JWKS endpoint and are cached; an unknown key id (a rotation) triggers one
  # refresh, rate limited so a flood of bad tokens cannot turn into a flood of fetches.
  class JwtVerifier
    class Error < StandardError; end          # the token is not acceptable
    class Unavailable < Error; end            # the key set could not be fetched

    ALGORITHMS = %w[RS256].freeze

    # +jwks+: a key set Hash to use as is (tests); otherwise it is fetched from +jwks_url+.
    def initialize(issuer:, audience:, jwks_url: nil, jwks: nil, cache_ttl: 600, min_refresh_interval: 30, leeway: 30, fetcher: nil)
      @issuer = issuer
      @audience = audience
      @jwks_url = jwks_url
      @static_jwks = jwks
      @cache_ttl = cache_ttl
      @min_refresh_interval = min_refresh_interval
      @leeway = leeway
      @fetcher = fetcher || method(:fetch_over_http)
      @mutex = Mutex.new
      @keys = nil
      @fetched_at = nil
    end

    # Returns the claims Hash of a valid token; raises Error otherwise.
    def verify!(token)
      kid = JWT::EncodedToken.new(token.to_s).header["kid"] rescue raise(Error, "malformed token")
      key = key_for(kid) or raise Error, "unknown signing key"

      # exp and sub are mandatory: a token that never expires, or names no one, is not acceptable.
      claims, = JWT.decode(token, key, true, algorithms: ALGORITHMS, iss: @issuer, verify_iss: true,
                           aud: @audience, verify_aud: true, exp_leeway: @leeway, nbf_leeway: @leeway,
                           required_claims: %w[exp sub])
      claims
    rescue JWT::DecodeError => error
      raise Error, error.message
    end

    private
      def key_for(kid)
        load_keys if stale?
        key = @keys&.dig(kid)
        return key if key

        load_keys(force: true)
        @keys&.dig(kid)
      end

      def stale? = @keys.nil? || monotonic - @fetched_at > @cache_ttl

      def load_keys(force: false)
        @mutex.synchronize do
          return if @keys && force && monotonic - @fetched_at < @min_refresh_interval
          return if @keys && !force && !stale?

          document = @static_jwks || @fetcher.call(@jwks_url)
          keys = JWT::JWK::Set.new(document).each_with_object({}) { |jwk, found| found[jwk[:kid]] = jwk.verify_key }
          raise Unavailable, "the key set contains no usable keys" if keys.empty?

          @keys = keys
          @fetched_at = monotonic
        end
      rescue Unavailable
        raise
      rescue JSON::ParserError, JWT::JWKError => error
        raise Unavailable, "invalid key set: #{error.message}"
      end

      def fetch_over_http(url)
        raise Unavailable, "no JWKS URL configured" unless url

        uri = URI(url)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 2, read_timeout: 3) { |http| http.get(uri.request_uri) }
        raise Unavailable, "JWKS endpoint answered #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)
      rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError => error
        raise Unavailable, "cannot reach the JWKS endpoint: #{error.class}"
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
