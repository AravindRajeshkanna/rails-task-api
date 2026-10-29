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

  class << self
    attr_writer :verifier

    def enabled? = Rails.configuration.x.auth.mode == "jwt"

    def verifier
      @verifier ||= ServiceKit::JwtVerifier.new(
        issuer: Rails.configuration.x.auth.issuer, audience: Rails.configuration.x.auth.audience, jwks_url: Rails.configuration.x.auth.jwks_url
      )
    end

    # A Session for the bearer +token+, or nil when it is not acceptable.
    def authenticate(token)
      return if token.blank?

      claims = verifier.verify!(token)
      Session.new(user: User.provision_from_claims!(claims), claims: claims)
    rescue ServiceKit::JwtVerifier::Unavailable => error
      raise Unavailable, error.message
    rescue ServiceKit::JwtVerifier::Error
      nil
    rescue ActiveRecord::RecordInvalid
      raise AccountConflict
    end
  end
end
