module AuthService
  # Mints access tokens: short-lived, stateless, verified by every service with the public key set.
  module TokenIssuer
    module_function

    # Returns [jwt, expires_at].
    def access_token(user, now: Time.current)
      config = Rails.configuration.x.auth
      expires_at = now + config.access_ttl
      claims = {
        iss: config.issuer, aud: config.audience, sub: user.uid, jti: SecureRandom.uuid,
        iat: now.to_i, nbf: now.to_i, exp: expires_at.to_i,
        email: user.email_address, name: user.name, legacy_id: user.legacy_id # legacy_id links pre-migration accounts
      }.compact

      [ JWT.encode(claims, Keys.signing_key, "RS256", { kid: Keys.kid, typ: "JWT" }), expires_at ]
    end

    # A fresh login: an access token plus a new refresh-token family, in the response shape clients use.
    def session_for(user, request)
      jwt, expires_at = access_token(user)
      record, refresh = RefreshToken.issue!(user, ip_address: request.remote_ip, user_agent: request.user_agent)
      payload(user, jwt, expires_at, refresh, record.expires_at)
    end

    # The same user continuing a family after a refresh.
    def payload(user, jwt, expires_at, refresh, refresh_expires_at)
      {
        token: jwt, expires_at: expires_at.utc.iso8601,
        refresh_token: refresh, refresh_expires_at: refresh_expires_at.utc.iso8601,
        user: { id: user.uid, name: user.name, email_address: user.email_address, created_at: user.created_at.utc.iso8601(3) }
      }
    end
  end
end
