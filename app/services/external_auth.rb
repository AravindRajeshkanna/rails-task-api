require "service_kit/jwt_verifier"

# AUTH_MODE=jwt: identity comes from the Auth service. This app verifies its access tokens locally
# (public keys from the JWKS endpoint) and keeps a local users row as a projection of the identity.
module ExternalAuth
  # Stands in for Session in Current when the request was authenticated by a JWT.
  Session = Struct.new(:user, :claims, keyword_init: true)

  # The email belongs to another, unlinked local account. Never merged automatically.
  class AccountConflict < StandardError; end

  # The Auth service's keys cannot be fetched; callers answer 503 rather than 401.
  Unavailable = Class.new(StandardError)

  # The identity belongs to a person who has been erased (AccountErasure): its tokens, issued before the Auth service deleted it, are not accepted.
  Erased = Class.new(StandardError)

  # The Auth service refused to check a password for now (its limit on attempts per address).
  RateLimited = Class.new(StandardError)

  class << self
    attr_writer :verifier

    def enabled? = Rails.configuration.x.auth.mode == "jwt"

    def verifier
      @verifier ||= ServiceKit::JwtVerifier.new(
        issuer: Rails.configuration.x.auth.issuer, audience: Rails.configuration.x.auth.audience, jwks_url: Rails.configuration.x.auth.jwks_url
      )
    end

    # Whether +password+ is +user+'s, asked of the Auth service that holds it: this application has no password for such a user. DELETE /me wants the
    # password again so that a stolen token alone cannot erase an account (ADR 67, 79). The Auth service answers 204 or 401 and keeps its own limit on
    # attempts per address, so this is no easier a way to guess a password than signing in. An Auth service that cannot be reached is Unavailable (503):
    # nothing is erased on a guess.
    def password_correct?(user, password)
      return false if password.blank?

      uri = URI.join(Rails.configuration.x.auth.jwks_url.to_s, "/api/v1/credential_checks")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 2
      http.read_timeout = 5
      request = Net::HTTP::Post.new(uri.request_uri, "Content-Type" => "application/json")
      request.body = { email_address: user.email_address, password: password }.to_json

      case (response = http.request(request))
      when Net::HTTPSuccess then true
      when Net::HTTPUnauthorized then false
      when Net::HTTPTooManyRequests then raise RateLimited
      else raise Unavailable, "the Auth service answered #{response.code}"
      end
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError, URI::InvalidURIError => error
      raise Unavailable, error.message
    end

    # A Session for the bearer +token+, or nil when it is not acceptable.
    def authenticate(token)
      return if token.blank?

      claims = verifier.verify!(token)
      Session.new(user: User.provision_from_claims!(claims), claims: claims)
    rescue ServiceKit::JwtVerifier::Unavailable => error
      raise Unavailable, error.message
    rescue ServiceKit::JwtVerifier::Error, Erased
      nil
    rescue ActiveRecord::RecordInvalid
      raise AccountConflict
    end
  end
end
