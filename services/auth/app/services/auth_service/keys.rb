module AuthService
  # The RS256 signing key and the public key set published at /.well-known/jwks.json.
  #
  #   AUTH_JWT_PRIVATE_KEY           PEM, or base64 of the PEM (easier to pass through env vars); 2048 bits or more
  #   AUTH_JWT_PREVIOUS_PUBLIC_KEYS  JSON array of PEM public keys that stay valid while a rotation rolls out
  #
  # Rotation: publish the new key's public half as "previous" on every verifier's source of truth (this
  # endpoint) first, then switch AUTH_JWT_PRIVATE_KEY, then drop the old key after the access TTL.
  # Without a private key, development and test generate a throwaway one per process; production refuses to boot.
  module Keys
    MIN_BITS = 2048

    class << self
      def signing_key = @signing_key ||= load_signing_key
      def kid = JWT::JWK.new(signing_key.public_key).kid # RFC 7638 thumbprint

      def jwks
        previous = JSON.parse(ENV.fetch("AUTH_JWT_PREVIOUS_PUBLIC_KEYS", "[]")).map { |pem| OpenSSL::PKey::RSA.new(pem) }
        { keys: ([ signing_key ] + previous).uniq(&:to_pem).map { |key| JWT::JWK.new(key.public_key, { alg: "RS256", use: "sig" }).export } }
      end

      def reset! = @signing_key = nil

      private
        def load_signing_key
          raw = ENV["AUTH_JWT_PRIVATE_KEY"].to_s.strip
          if raw.empty?
            raise "AUTH_JWT_PRIVATE_KEY must be set in production" if Rails.env.production?

            Rails.logger.warn("AUTH_JWT_PRIVATE_KEY is not set: using a throwaway key. Tokens will not survive a restart.")
            return OpenSSL::PKey::RSA.generate(MIN_BITS)
          end

          pem = raw.include?("BEGIN") ? raw.gsub("\\n", "\n") : Base64.decode64(raw)
          OpenSSL::PKey::RSA.new(pem).tap { |key| raise "AUTH_JWT_PRIVATE_KEY must be at least #{MIN_BITS} bits" if key.n.num_bits < MIN_BITS }
        end
    end
  end
end
