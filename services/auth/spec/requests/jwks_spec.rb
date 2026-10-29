require "rails_helper"

RSpec.describe "GET /.well-known/jwks.json", type: :request do
  it "publishes the public key, never the private one, and lets clients cache it" do
    get "/.well-known/jwks.json"

    expect(response).to have_http_status(:ok)
    key = json["keys"].sole
    expect(key).to include("kty" => "RSA", "alg" => "RS256", "use" => "sig", "kid" => AuthService::Keys.kid)
    expect(key.keys).not_to include("d", "p", "q", "dp", "dq", "qi")
    expect(response.headers["Cache-Control"]).to include("public", "max-age=300")
  end

  it "keeps previous public keys during a rotation, so tokens signed by them still verify" do
    old_key = OpenSSL::PKey::RSA.generate(2048)
    old_token = JWT.encode({ iss: Rails.configuration.x.auth.issuer, aud: "task-api", sub: "u", exp: 5.minutes.from_now.to_i }, old_key, "RS256", { kid: JWT::JWK.new(old_key.public_key).kid })

    ENV["AUTH_JWT_PREVIOUS_PUBLIC_KEYS"] = [ old_key.public_key.to_pem ].to_json
    get "/.well-known/jwks.json"

    expect(json["keys"].size).to eq(2)
    verifier = ServiceKit::JwtVerifier.new(issuer: Rails.configuration.x.auth.issuer, audience: "task-api", jwks: json)
    expect(verifier.verify!(old_token)["sub"]).to eq("u")
  ensure
    ENV.delete("AUTH_JWT_PREVIOUS_PUBLIC_KEYS")
  end

  it "accepts the signing key as PEM or base64, and refuses keys that are too small" do
    key = OpenSSL::PKey::RSA.generate(2048)
    ENV["AUTH_JWT_PRIVATE_KEY"] = Base64.strict_encode64(key.to_pem)
    AuthService::Keys.reset!
    expect(AuthService::Keys.signing_key.to_pem).to eq(key.to_pem)

    ENV["AUTH_JWT_PRIVATE_KEY"] = OpenSSL::PKey::RSA.generate(1024).to_pem
    AuthService::Keys.reset!
    expect { AuthService::Keys.signing_key }.to raise_error(/at least 2048 bits/)
  ensure
    ENV.delete("AUTH_JWT_PRIVATE_KEY")
    AuthService::Keys.reset!
  end
end
