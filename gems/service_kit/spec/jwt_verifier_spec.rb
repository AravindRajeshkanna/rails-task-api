require "spec_helper"
require "service_kit/jwt_verifier"

RSpec.describe ServiceKit::JwtVerifier do
  let(:key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:other_key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:now) { Time.now.to_i }
  let(:claims) { { "iss" => "https://auth.test", "aud" => "task-api", "sub" => "user-1", "exp" => now + 900, "iat" => now } }

  def jwks_for(*keys_with_kids)
    { "keys" => keys_with_kids.map { |(rsa, kid)| JWT::JWK.new(rsa.public_key, kid: kid).export } }
  end

  def token(payload = claims, signing_key: key, kid: "k1", alg: "RS256")
    JWT.encode(payload, signing_key, alg, { kid: kid })
  end

  def verifier(jwks: jwks_for([ key, "k1" ]), **options)
    described_class.new(issuer: "https://auth.test", audience: "task-api", jwks: jwks, **options)
  end

  it "returns the claims of a valid token" do
    expect(verifier.verify!(token)).to include("sub" => "user-1", "aud" => "task-api")
  end

  {
    "an expired token" => ->(c) { c.merge("exp" => Time.now.to_i - 3_600) },
    "another issuer" => ->(c) { c.merge("iss" => "https://evil.test") },
    "another audience" => ->(c) { c.merge("aud" => "billing") },
    "a missing expiry" => ->(c) { c.except("exp") }
  }.each do |name, change|
    it "rejects #{name}" do
      expect { verifier.verify!(token(change.call(claims))) }.to raise_error(described_class::Error)
    end
  end

  it "rejects a token signed with someone else's key, even if it claims our key id" do
    expect { verifier.verify!(token(signing_key: other_key)) }.to raise_error(described_class::Error, /signature/i)
  end

  it "rejects an unknown key id" do
    expect { verifier.verify!(token(kid: "unknown")) }.to raise_error(described_class::Error, /unknown signing key/)
  end

  it "rejects alg=none and symmetric algorithms (algorithm confusion)" do
    none = JWT.encode(claims, nil, "none", { kid: "k1" })
    hs256 = JWT.encode(claims, key.public_key.to_pem, "HS256", { kid: "k1" })

    [ none, hs256 ].each { |forged| expect { verifier.verify!(forged) }.to raise_error(described_class::Error) }
  end

  it "rejects garbage" do
    [ "", "abc", "a.b.c", nil ].each { |garbage| expect { verifier.verify!(garbage) }.to raise_error(described_class::Error) }
  end

  describe "key rotation" do
    it "refetches once when it meets an unknown key id, then accepts tokens from the new key" do
      documents = [ jwks_for([ key, "k1" ]), jwks_for([ key, "k1" ], [ other_key, "k2" ]) ]
      fetches = 0
      fetcher = ->(_url) { documents[[ fetches, 1 ].min].tap { fetches += 1 } }
      verifier = described_class.new(issuer: "https://auth.test", audience: "task-api", jwks_url: "http://auth/jwks", fetcher: fetcher, min_refresh_interval: 0)

      expect(verifier.verify!(token)).to include("sub" => "user-1")
      expect(verifier.verify!(token(signing_key: other_key, kid: "k2"))).to include("sub" => "user-1")
      expect(fetches).to eq(2)
    end

    it "does not refetch on every bad token" do
      fetches = 0
      fetcher = ->(_url) { fetches += 1; jwks_for([ key, "k1" ]) }
      verifier = described_class.new(issuer: "https://auth.test", audience: "task-api", jwks_url: "x", fetcher: fetcher, min_refresh_interval: 60)

      5.times { expect { verifier.verify!(token(kid: "nope")) }.to raise_error(described_class::Error) }

      expect(fetches).to eq(1)
    end

    it "caches the key set between tokens" do
      fetches = 0
      fetcher = ->(_url) { fetches += 1; jwks_for([ key, "k1" ]) }
      verifier = described_class.new(issuer: "https://auth.test", audience: "task-api", jwks_url: "x", fetcher: fetcher)

      3.times { verifier.verify!(token) }

      expect(fetches).to eq(1)
    end
  end

  it "reports an unreachable key set as unavailable (a 503, not a 401)" do
    verifier = described_class.new(issuer: "i", audience: "a", jwks_url: "x", fetcher: ->(_) { raise described_class::Unavailable, "down" })

    expect { verifier.verify!(token) }.to raise_error(described_class::Unavailable, "down")
  end

  it "reports a malformed key set as unavailable" do
    verifier = described_class.new(issuer: "i", audience: "a", jwks_url: "x", fetcher: ->(_) { { "keys" => [ { "kty" => "nope" } ] } })

    expect { verifier.verify!(token) }.to raise_error(described_class::Unavailable)
  end

  describe "when the Auth service goes down" do
    let(:time) { [ 0.0 ] }
    let(:fetches) { [] }
    let(:up) { [ true ] }
    let(:fetcher) do
      lambda do |_url|
        fetches << time.first
        raise described_class::Unavailable, "down" unless up.first

        jwks_for([ key, "k1" ])
      end
    end
    let(:verifier) do
      described_class.new(issuer: "https://auth.test", audience: "task-api", jwks_url: "x", fetcher: fetcher, clock: -> { time.first },
                          cache_ttl: 600, min_refresh_interval: 30, max_stale: 3_600)
    end

    it "keeps accepting tokens signed with the keys it already holds, instead of rejecting every request" do
      verifier.verify!(token)
      up[0] = false
      time[0] += 601 # the cache is now stale

      expect(verifier.verify!(token)).to include("sub" => "user-1")
    end

    it "tries to refetch once per interval, not once per request" do
      verifier.verify!(token)
      up[0] = false
      time[0] += 601
      fetches.clear

      50.times { verifier.verify!(token) }
      expect(fetches.size).to eq(1)

      time[0] += 31
      verifier.verify!(token)
      expect(fetches.size).to eq(2)
    end

    it "recovers by itself when the service comes back, and picks up a rotation made meanwhile" do
      verifier.verify!(token)
      up[0] = false
      time[0] += 700
      verifier.verify!(token)
      up[0] = true
      time[0] += 31

      expect(verifier.verify!(token)).to include("sub" => "user-1")
      expect(fetches.last).to eq(time.first)
    end

    it "stops trusting stale keys after max_stale, because a key that was revoked must not live forever" do
      verifier.verify!(token)
      up[0] = false
      time[0] += 3_700

      expect { verifier.verify!(token) }.to raise_error(described_class::Unavailable)
    end

    it "fails fast when it never had keys, instead of fetching on every request" do
      up[0] = false

      20.times { expect { verifier.verify!(token) }.to raise_error(described_class::Unavailable) }

      expect(fetches.size).to eq(1)
    end

    it "still rejects a token it cannot verify while serving stale keys (an unknown key is not a reason to trust)" do
      verifier.verify!(token)
      up[0] = false
      time[0] += 601

      expect { verifier.verify!(token(signing_key: other_key, kid: "k2")) }.to raise_error(described_class::Error, "unknown signing key")
    end
  end
end
