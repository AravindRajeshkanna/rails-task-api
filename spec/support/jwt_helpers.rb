# Issues access tokens the way the Auth service does, signed with a throwaway key, for AUTH_MODE=jwt specs.
module JwtHelpers
  ISSUER = "https://auth.test".freeze

  def self.key = @key ||= OpenSSL::PKey::RSA.generate(2048)
  def self.jwks(key = self.key, kid: "test-key") = { "keys" => [ JWT::JWK.new(key.public_key, kid: kid).export ] }

  def jwt_for(sub: "auth-user-1", email: "person@example.com", name: "Pat Person", legacy_id: nil, exp: 15.minutes.from_now.to_i, aud: "task-api", iss: ISSUER, key: JwtHelpers.key, kid: "test-key", **extra)
    claims = { iss: iss, aud: aud, sub: sub, email: email, name: name, iat: Time.now.to_i, exp: exp, legacy_id: legacy_id }.compact.merge(extra)
    JWT.encode(claims, key, "RS256", { kid: kid })
  end

  def jwt_headers(**claims) = { "Authorization" => "Bearer #{jwt_for(**claims)}" }

  # Runs the block as a deployment with AUTH_MODE=jwt would behave.
  def with_jwt_auth(jwks: JwtHelpers.jwks)
    config = Rails.configuration.x.auth
    original = { mode: config.mode, issuer: config.issuer, audience: config.audience }
    config.mode = "jwt"
    config.issuer = ISSUER
    config.audience = "task-api"
    ExternalAuth.verifier = ServiceKit::JwtVerifier.new(issuer: ISSUER, audience: "task-api", jwks: jwks)
    yield
  ensure
    original.each { |key, value| config[key] = value }
    ExternalAuth.verifier = nil
  end
end

RSpec.configure { |config| config.include JwtHelpers }
