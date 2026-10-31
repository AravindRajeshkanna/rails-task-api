module KmsEncryption
  # An in-memory stand-in for KMS, for development and tests: no network, no AWS account. It behaves like KMS where the code relies on it. A data key
  # is wrapped under a named key (a different key fails to unwrap it), the encryption context is authenticated (a different context fails), and the
  # key it reports is a bare key id. It is NOT secure: the wrapping keys derive from public strings. `Configuration` refuses it in production.
  class LocalClient
    Request = Struct.new(:operation, :key_id, :context)

    attr_reader :requests

    def initialize
      @requests = []
      @mutex = Mutex.new
    end

    def generate_data_key(key_id:, context:)
      record(:generate_data_key, key_id, context)
      resolved = resolve(key_id)
      plaintext = SecureRandom.random_bytes(32)
      DataKey.new(plaintext, wrap(plaintext, resolved, context), resolved)
    end

    # Like KMS, the key id is optional: the wrapped key says which key made it.
    def decrypt(ciphertext_blob:, context:, key_id: nil)
      record(:decrypt, key_id, context)
      unwrap(ciphertext_blob, key_id && resolve(key_id), context)
    end

    def reset! = @mutex.synchronize { @requests.clear }

    def count(operation) = @mutex.synchronize { @requests.count { |request| request.operation == operation } }

    private
      PREFIX = "local-insecure:".b.freeze

      def record(operation, key_id, context)
        @mutex.synchronize { @requests << Request.new(operation, key_id, context.dup) }
      end

      # "alias/task-api-dev-data" and "local-task-api-dev-data" name the same key; so does an ARN ending in key/local-...
      def resolve(key_id)
        name = key_id.to_s.split("/").last
        name.start_with?("local-") ? name : "local-#{name}"
      end

      def wrapping_key(resolved) = OpenSSL::Digest.digest('SHA256', "insecure-local-kms-key/#{resolved}")

      def canonical(context) = JSON.generate(context.sort.to_h)

      # The wrapped form carries the key it was made under (as a real KMS ciphertext does), so Decrypt can work without being told.
      def wrap(plaintext, resolved, context)
        cipher = OpenSSL::Cipher.new("aes-256-gcm").encrypt
        cipher.key = wrapping_key(resolved)
        iv = cipher.random_iv
        cipher.auth_data = canonical(context)
        sealed = cipher.update(plaintext) + cipher.final
        header = [ resolved.bytesize ].pack("n") + resolved.b
        PREFIX + header + iv + cipher.auth_tag + sealed
      end

      def unwrap(blob, expected, context)
        blob = blob.b
        raise InvalidCiphertext, "not a local wrapped key" unless blob.start_with?(PREFIX)

        rest = blob.byteslice(PREFIX.bytesize..)
        length = rest.unpack1("n")
        resolved = rest.byteslice(2, length)
        raise InvalidCiphertext, "wrapped under #{resolved}, not #{expected}" if expected && expected != resolved

        body = rest.byteslice(2 + length..)
        iv, tag, sealed = body.byteslice(0, 12), body.byteslice(12, 16), body.byteslice(28..)
        cipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
        cipher.key = wrapping_key(resolved)
        cipher.iv = iv
        cipher.auth_tag = tag
        cipher.auth_data = canonical(context)
        cipher.update(sealed) + cipher.final
      rescue OpenSSL::Cipher::CipherError
        raise InvalidCiphertext, "the wrapped key does not unwrap under this key and encryption context"
      end
  end
end
