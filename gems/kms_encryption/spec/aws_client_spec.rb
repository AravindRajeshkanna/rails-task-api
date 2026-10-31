require "spec_helper"
require "kms_encryption"
require "aws-sdk-kms"

RSpec.describe KmsEncryption::AwsClient do
  let(:sdk) { Aws::KMS::Client.new(stub_responses: true, region: "us-east-1", credentials: Aws::Credentials.new("id", "secret")) }
  let(:client) { described_class.new(client: sdk) }
  let(:context) { { "app" => "task-api", "table" => "webhooks" } }
  let(:key_arn) { "arn:aws:kms:us-east-1:123456789012:key/mrk-1234abcd12ab34cd56ef1234567890ab" }

  def requests(name) = sdk.api_requests.select { |request| request[:operation_name] == name }.map { |request| request[:params] }

  describe "#generate_data_key" do
    before { sdk.stub_responses(:generate_data_key, plaintext: "p" * 32, ciphertext_blob: "wrapped", key_id: key_arn) }

    it "asks for one AES-256 key, with the encryption context, in a single request" do
      client.generate_data_key(key_id: "alias/task-api-dev-data", context: context)

      expect(requests(:generate_data_key)).to eq([ { key_id: "alias/task-api-dev-data", key_spec: "AES_256", encryption_context: context } ])
    end

    it "returns the key in both forms and the bare id of the key that made it, which names it from any region" do
      data_key = client.generate_data_key(key_id: "alias/task-api-dev-data", context: context)

      expect([ data_key.plaintext, data_key.ciphertext, data_key.key_id ]).to eq([ "p" * 32, "wrapped", "mrk-1234abcd12ab34cd56ef1234567890ab" ])
    end
  end

  describe "#decrypt" do
    before { sdk.stub_responses(:decrypt, plaintext: "p" * 32) }

    it "names the key and the context, so KMS refuses a wrapped key made under anything else" do
      client.decrypt(ciphertext_blob: "wrapped", key_id: "mrk-1234", context: context)

      expect(requests(:decrypt)).to eq([ { ciphertext_blob: "wrapped", encryption_context: context, encryption_algorithm: "SYMMETRIC_DEFAULT", key_id: "mrk-1234" } ])
    end

    it "does not send a key id when none is given" do
      client.decrypt(ciphertext_blob: "wrapped", context: context)

      expect(requests(:decrypt).first).not_to have_key(:key_id)
    end
  end

  describe "errors" do
    def failing(operation, code)
      sdk.stub_responses(operation, code)
      -> { operation == :decrypt ? client.decrypt(ciphertext_blob: "x", context: context) : client.generate_data_key(key_id: "alias/k", context: context) }
    end

    it "calls a wrapped key that does not unwrap invalid ciphertext, not an outage" do
      %w[InvalidCiphertextException IncorrectKeyException].each do |code|
        expect(&failing(:decrypt, code)).to raise_error(KmsEncryption::InvalidCiphertext, /#{code}/)
      end
    end

    it "calls everything that stops KMS answering unavailable, with the reason" do
      {
        "AccessDeniedException" => :access_denied, "DisabledException" => :key_unusable, "KMSInvalidStateException" => :key_unusable,
        "NotFoundException" => :key_unusable, "ThrottlingException" => :throttled, "LimitExceededException" => :throttled, "KMSInternalException" => :service
      }.each do |code, reason|
        expect(&failing(:generate_data_key, code)).to raise_error(KmsEncryption::Unavailable) { |error| expect(error.reason).to eq(reason), code }
      end
    end

    it "calls a timeout or a refused connection a network problem" do
      sdk.stub_responses(:decrypt, Seahorse::Client::NetworkingError.new(Net::ReadTimeout.new))

      expect { client.decrypt(ciphertext_blob: "x", context: context) }.to raise_error(KmsEncryption::Unavailable) { |error| expect(error.reason).to eq(:network) }
    end
  end

  describe "instrumentation" do
    def events
      [].tap do |collected|
        subscriber = ActiveSupport::Notifications.subscribe("request.kms_encryption") { |event| collected << [ event.payload[:operation], event.payload[:outcome] ] }
        yield
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end
    end

    it "reports each request with its outcome" do
      sdk.stub_responses(:generate_data_key, plaintext: "p" * 32, ciphertext_blob: "w", key_id: key_arn)
      sdk.stub_responses(:decrypt, "ThrottlingException")

      seen = events do
        client.generate_data_key(key_id: "alias/k", context: context)
        client.decrypt(ciphertext_blob: "x", context: context) rescue nil
      end

      expect(seen).to eq([ %w[generate_data_key ok], %w[decrypt throttled] ])
    end
  end
end
