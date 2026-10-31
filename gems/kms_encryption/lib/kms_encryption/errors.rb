module KmsEncryption
  class Error < StandardError; end

  # Encryption is not set up: no key id in production, no wrapped deterministic key, no key source. Retrying will not help; the configuration is wrong.
  class NotConfigured < Error; end

  # KMS could not be used right now (throttled, unreachable, access denied, key disabled). The data is not known to be bad. Kept apart from
  # ActiveRecord::Encryption::Errors::Decryption, which means "these bytes do not decrypt", so an outage is never reported as corruption.
  class Unavailable < Error
    # :access_denied, :key_unusable, :throttled, :network, :credentials or :service
    attr_reader :reason

    def initialize(message, reason: :service)
      super(message)
      @reason = reason
    end
  end

  # A wrapped data key does not unwrap under the key and encryption context it claims: damaged, copied from another attribute, or the wrong key.
  class InvalidCiphertext < Error; end
end
