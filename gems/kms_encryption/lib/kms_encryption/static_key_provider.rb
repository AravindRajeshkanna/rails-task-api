module KmsEncryption
  # The key provider for deterministic encryption, where the same text must always give the same ciphertext (so that `where(email_address: ...)` can
  # find it). That rules out a fresh data key per value, and Rails never consults the configured provider for a deterministic attribute anyway: it
  # reads `deterministic_key` from its own credentials.
  #
  # Here one master secret is generated once and wrapped by KMS; the wrapped form is configuration (it is useless without kms:Decrypt on the key). Each
  # process asks KMS to unwrap it ONCE, on first use, and then derives a separate key per attribute from it (HKDF, with the attribute as `info`), so
  # the same address in two tables does not give the same ciphertext. After that, no request touches KMS: sign-in, lookups and listings are unaffected
  # by KMS latency or an outage. The cost is that a process holds the master in memory for its lifetime.
  class StaticKeyProvider
    def initialize(info:, wrapped_key: nil)
      @info = info.to_s
      @wrapped_key = wrapped_key
      @mutex = Mutex.new
    end

    def encryption_key = key

    def decryption_keys(_encrypted_message) = [ key ]

    private
      def key
        @key || @mutex.synchronize do
          @key ||= ActiveRecord::Encryption::Key.new(
            OpenSSL::KDF.hkdf(KmsEncryption.deterministic_master(@wrapped_key), salt: "", info: "#{KmsEncryption.configuration.app}/#{@info}", length: 32, hash: "SHA256")
          )
        end
      end
  end
end
