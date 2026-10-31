module KmsEncryption
  # An Active Record Encryption key provider that does envelope encryption with KMS. Each encrypted value gets its own random data key from KMS
  # (GenerateDataKey); Rails encrypts the value with it (AES-256-GCM); the wrapped copy of the key travels in the value's own header, next to the id of
  # the KMS key that wrapped it. Reading the value asks KMS to unwrap the key (Decrypt), once per key per `cache_ttl`.
  #
  #   encrypts :secret, key_provider: KmsEncryption.key_provider(table: "webhooks", attribute: "secret")
  #
  # Rails calls a provider without telling it which record it is for, so the encryption context can name the table and attribute but not the row (a new
  # row has no id yet). It binds a wrapped key to the application and the attribute: one copied from another attribute will not unwrap.
  class KeyProvider
    # The marker in the header that says "this value is ours"; anything else (a Rails-keyed value from before, say) is left to Rails' previous schemes.
    HEADER_PREFIX = "kms:".freeze

    attr_reader :context

    def initialize(context: {})
      @context = context.to_h.to_h { |name, value| [ name.to_s, value.to_s ] }.freeze
    end

    def encryption_key
      data_key = KmsEncryption.client.generate_data_key(key_id: KmsEncryption.key_id!, context: full_context)
      # Rails reads back what it has just written (to reset the record's change tracking). We hold the key, so that read is free; without this, every
      # write was a GenerateDataKey and a Decrypt of the same key.
      KmsEncryption.cache.store(cache_key(data_key.key_id, data_key.ciphertext), data_key.plaintext)
      ActiveRecord::Encryption::Key.new(data_key.plaintext).tap do |key|
        key.public_tags.encrypted_data_key = data_key.ciphertext # the serializer encodes it (Base64 in JSON), so no layer of our own
        key.public_tags.encrypted_data_key_id = "#{HEADER_PREFIX}#{data_key.key_id}"
      end
    end

    # [] means "not mine" and lets Rails try the previous schemes. A KMS failure is raised as itself: an outage is not a decryption error.
    def decryption_keys(encrypted_message)
      reference = encrypted_message.headers.encrypted_data_key_id
      return [] unless reference.is_a?(String) && reference.start_with?(HEADER_PREFIX)

      key_id = reference.delete_prefix(HEADER_PREFIX)
      wrapped = wrapped_key(encrypted_message)
      plaintext = KmsEncryption.cache.fetch(cache_key(key_id, wrapped)) do
        KmsEncryption.client.decrypt(ciphertext_blob: wrapped, key_id: key_id, context: full_context)
      end
      [ ActiveRecord::Encryption::Key.new(plaintext) ]
    end

    private
      def full_context = KmsEncryption.configuration.base_context.merge(context)

      def cache_key(key_id, wrapped) = Digest::SHA256.hexdigest([ key_id, JSON.generate(full_context.sort.to_h), wrapped ].join("\0"))

      def wrapped_key(encrypted_message)
        wrapped = encrypted_message.headers.encrypted_data_key
        wrapped.is_a?(String) && !wrapped.empty? ? wrapped : raise(InvalidCiphertext, "the header names a KMS key but holds no wrapped data key")
      end
  end
end
