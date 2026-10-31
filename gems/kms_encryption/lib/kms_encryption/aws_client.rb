module KmsEncryption
  DataKey = Struct.new(:plaintext, :ciphertext, :key_id)

  # The two KMS requests this library makes, with errors sorted into "KMS is unavailable" (an operations problem: retry, fix access) and "this wrapped
  # key is invalid" (a data problem), and one ActiveSupport notification per request for metrics and logs.
  #
  #   GenerateDataKey  once per encrypted value: returns a fresh key in plaintext and wrapped. One request where Encrypt-a-random-key would take two,
  #                    and the one permission (kms:GenerateDataKey) to write.
  #   Decrypt          to unwrap a key, or the master key at start-up; cached afterwards.
  class AwsClient
    # Short timeouts and one retry: this runs inside a request. A slow KMS must not hold a thread for the SDK's defaults.
    DEFAULTS = { retry_limit: 1, http_open_timeout: 2, http_read_timeout: 2 }.freeze

    ACCESS_DENIED = %w[AccessDeniedException UnrecognizedClientException InvalidSignatureException ExpiredTokenException].freeze
    KEY_UNUSABLE = %w[DisabledException KMSInvalidStateException NotFoundException KeyUnavailableException InvalidKeyUsageException InvalidGrantTokenException].freeze
    THROTTLED = %w[ThrottlingException LimitExceededException RequestLimitExceeded TooManyRequestsException].freeze
    INVALID_CIPHERTEXT = %w[InvalidCiphertextException IncorrectKeyException].freeze

    def initialize(region: nil, endpoint: nil, client: nil)
      @client = client || build(region, endpoint)
    end

    def generate_data_key(key_id:, context:)
      response = request("generate_data_key") do
        @client.generate_data_key(key_id: key_id, key_spec: "AES_256", encryption_context: context)
      end
      # response.key_id is the key's ARN. Keep the bare id: it names the same key from any region, which a multi-Region key needs after a failover.
      DataKey.new(response.plaintext, response.ciphertext_blob, response.key_id.to_s.split("/").last)
    end

    def decrypt(ciphertext_blob:, context:, key_id: nil)
      arguments = { ciphertext_blob: ciphertext_blob, encryption_context: context, encryption_algorithm: "SYMMETRIC_DEFAULT" }
      arguments[:key_id] = key_id if key_id # naming the key makes KMS refuse a wrapped key made under any other
      request("decrypt") { @client.decrypt(**arguments) }.plaintext
    end

    private
      def build(region, endpoint)
        require "aws-sdk-kms"
        options = DEFAULTS.dup
        options[:region] = region if region
        options[:endpoint] = endpoint if endpoint
        Aws::KMS::Client.new(**options)
      end

      def request(operation)
        ActiveSupport::Notifications.instrument("request.kms_encryption", operation: operation) do |payload|
          payload[:outcome] = "ok"
          yield
        rescue StandardError => error
          translated = translate(error)
          payload[:outcome] = translated.is_a?(Unavailable) ? translated.reason.to_s : "invalid_ciphertext"
          raise translated
        end
      end

      def translate(error)
        code = error.respond_to?(:code) ? error.code.to_s : error.class.name.to_s.split("::").last
        case code
        when *INVALID_CIPHERTEXT then InvalidCiphertext.new("#{code}: #{error.message}")
        when *ACCESS_DENIED then Unavailable.new("#{code}: #{error.message}", reason: :access_denied)
        when *KEY_UNUSABLE then Unavailable.new("#{code}: #{error.message}", reason: :key_unusable)
        when *THROTTLED then Unavailable.new("#{code}: #{error.message}", reason: :throttled)
        else
          reason = network?(error) ? :network : (credentials?(error) ? :credentials : :service)
          Unavailable.new("#{error.class}: #{error.message}", reason: reason)
        end
      end

      def network?(error)
        error.is_a?(Timeout::Error) || error.is_a?(SocketError) || error.is_a?(SystemCallError) || error.class.name.to_s.include?("Networking") ||
          (defined?(Seahorse::Client::NetworkingError) && error.is_a?(Seahorse::Client::NetworkingError))
      end

      def credentials?(error) = error.class.name.to_s.include?("MissingCredentials") || error.class.name.to_s.include?("NoSuchEndpoint")
  end
end
