require "active_support"
require "active_support/notifications"
require "active_support/core_ext/object/blank"
require "active_record"
require "base64"
require "digest"
require "json"
require "openssl"
require "securerandom"

require_relative "kms_encryption/version"
require_relative "kms_encryption/errors"
require_relative "kms_encryption/key_cache"
require_relative "kms_encryption/local_client"
require_relative "kms_encryption/aws_client"
require_relative "kms_encryption/configuration"
require_relative "kms_encryption/key_provider"
require_relative "kms_encryption/static_key_provider"

# Key providers for Active Record Encryption whose keys are protected by AWS KMS (docs/aws/kms.md, ADR 69). See KeyProvider and StaticKeyProvider.
module KmsEncryption
  # What the wrapped master key is bound to. deploy/terraform/kms.tf wraps it with exactly this context; a spec keeps the two equal.
  MASTER_PURPOSE = "deterministic-master".freeze
  LOCAL_MASTER = OpenSSL::Digest.digest('SHA256', "insecure-local-deterministic-master").freeze

  class << self
    def configuration = (@configuration ||= Configuration.new)

    def configure
      yield configuration
      reset!
    end

    # Forget cached keys and the unwrapped master (tests; or after the configuration changed).
    def reset!
      @cache = nil
      @masters = {}
    end

    def client = configuration.client

    def credentials? = configuration.credentials?

    def key_id!
      configuration.key_id.to_s.strip.then { |id| id.empty? ? raise(NotConfigured, "KMS_KEY_ID is not set") : id }
    end

    def cache = (@cache ||= KeyCache.new(ttl: configuration.cache_ttl, size: configuration.cache_size))

    # For one attribute: `KmsEncryption.key_provider(table: "webhooks", attribute: "secret")`. The keywords become the encryption context.
    def key_provider(**context) = KeyProvider.new(context: context)

    # For one deterministic attribute, with its own key derived from the master. `wrapped_key:` names an older master (a previous scheme during rotation).
    def deterministic_key_provider(info:, wrapped_key: nil) = StaticKeyProvider.new(info: info, wrapped_key: wrapped_key)

    def master_context = configuration.base_context.merge("purpose" => MASTER_PURPOSE)

    # The unwrapped master secret, unwrapped once per process per wrapped value. Raises NotConfigured or Unavailable; a failure is not remembered.
    def deterministic_master(wrapped = nil)
      wrapped = wrapped.presence || configuration.wrapped_deterministic_key.presence
      return LOCAL_MASTER if wrapped.nil? && configuration.local?
      raise NotConfigured, "KMS_WRAPPED_DETERMINISTIC_KEY is not set: nothing to derive the keys of deterministic attributes from" if wrapped.nil?

      @masters ||= {}
      @master_lock ||= Mutex.new
      @master_lock.synchronize do
        @masters[wrapped] ||= client.decrypt(ciphertext_blob: Base64.strict_decode64(wrapped), context: master_context)
      end
    rescue ArgumentError
      raise InvalidCiphertext, "the wrapped deterministic key is not valid base64"
    end

    # The id of the key new values are made under (what the alias points at now): one GenerateDataKey, whose key is thrown away. It is how a stored value's key id
    # is compared with "current" after a rotation. Needs the same permission as writing a value.
    def current_key_id = client.generate_data_key(key_id: key_id!, context: configuration.base_context).key_id

    # A new master, wrapped, for an operator to store as KMS_WRAPPED_DETERMINISTIC_KEY. The plaintext is discarded here and never printed.
    def generate_wrapped_master
      data_key = client.generate_data_key(key_id: key_id!, context: master_context)
      Base64.strict_encode64(data_key.ciphertext)
    end

    # Can this process encrypt and decrypt right now? Behind the readiness probe. Unwrapping the master is the one thing that needs KMS at start-up;
    # once done it is remembered, so a probe costs nothing and a later KMS outage does not take a serving pod out of rotation.
    def ready?
      case configuration.source
      when :local then true
      when :credentials then ActiveRecord::Encryption.config.has_primary_key? && ActiveRecord::Encryption.config.has_deterministic_key? ? true : false
      when :kms then !deterministic_master.nil?
      else false
      end
    rescue Error
      false
    end
  end
end
