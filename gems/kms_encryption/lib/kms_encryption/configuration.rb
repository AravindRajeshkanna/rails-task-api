module KmsEncryption
  class Configuration
    # kms          keys are protected by AWS KMS (production on AWS)
    # credentials  Rails' own keys from config/credentials.yml.enc: for deployments that are not on AWS (Kamal, docker compose)
    # local        an in-memory stand-in for KMS with a fixed, public key. Development and tests only; refused anywhere else.
    SOURCES = %i[kms credentials local].freeze

    attr_accessor :key_id, :wrapped_deterministic_key, :endpoint, :region, :app, :cache_ttl, :cache_size

    # Earlier masters, newest first, still readable while their values are being moved to the current one (docs/runbooks/kms-key-rotation.md).
    attr_writer :previous_wrapped_deterministic_keys
    attr_reader :source
    attr_writer :client

    def initialize
      @app = "task-api"
      @cache_ttl = 300 # seconds
      @cache_size = 1_000
    end

    def source=(value)
      value = value&.to_sym
      raise ArgumentError, "unknown key source #{value.inspect}; use one of #{SOURCES.join(', ')}" unless value.nil? || SOURCES.include?(value)

      @source = value
      @client = nil
    end

    def previous_wrapped_deterministic_keys = (@previous_wrapped_deterministic_keys ||= [])

    def kms? = source == :kms
    def credentials? = source == :credentials
    def local? = source == :local

    def client = (@client ||= build_client)

    # The encryption context every request carries. KMS records it in CloudTrail and requires the same one to decrypt, and an IAM or key policy can
    # require it (kms:EncryptionContext:app), so a call that does not name the application is refused.
    def base_context = { "app" => app }

    private
      def build_client
        case source
        when :local then LocalClient.new
        when :kms
          raise NotConfigured, "ENCRYPTION_KEY_SOURCE is kms but KMS_KEY_ID is not set" if key_id.to_s.strip.empty?

          AwsClient.new(region: region, endpoint: endpoint)
        when :credentials
          raise NotConfigured, "the key source is credentials: Rails' own keys are in use and KMS is not"
        else
          raise NotConfigured, "no key source: set KMS_KEY_ID (AWS KMS) or ENCRYPTION_KEY_SOURCE=credentials (Rails credentials keys)"
        end
      end
  end
end
