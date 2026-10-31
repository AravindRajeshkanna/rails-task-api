require "spec_helper"
require "kms_encryption"
require "kms_encryption/testing"

RSpec.describe KmsEncryption do
  describe "the key source" do
    it "accepts the three sources and nothing else" do
      configuration = KmsEncryption::Configuration.new
      %i[kms credentials local].each { |source| expect { configuration.source = source }.not_to raise_error }
      expect { configuration.source = :plaintext }.to raise_error(ArgumentError, /unknown key source/)
    end

    it "builds no client when there is no source, and says what to set" do
      KmsEncryption::Testing.isolated(source: nil) do
        expect { KmsEncryption.client }.to raise_error(KmsEncryption::NotConfigured, /KMS_KEY_ID.*credentials/)
      end
    end

    it "needs a key id before it will build an AWS client" do
      KmsEncryption::Testing.isolated(source: :kms) do
        expect { KmsEncryption.client }.to raise_error(KmsEncryption::NotConfigured, /KMS_KEY_ID/)
      end
    end

    it "builds the AWS client when it has a key id, with short timeouts and one retry, because it runs inside requests" do
      require "aws-sdk-kms"
      expect(Aws::KMS::Client).to receive(:new)
        .with(retry_limit: 1, http_open_timeout: 2, http_read_timeout: 2, region: "us-east-1", endpoint: "http://localhost:4566").and_return(Object.new)

      KmsEncryption::Testing.isolated(source: :kms, key_id: "alias/task-api-dev-data", region: "us-east-1", endpoint: "http://localhost:4566") do
        expect(KmsEncryption.client).to be_a(KmsEncryption::AwsClient)
      end
    end

    it "does not ask KMS for anything when the keys are Rails' own" do
      KmsEncryption::Testing.isolated(source: :credentials) do
        expect(KmsEncryption.credentials?).to be(true)
        expect { KmsEncryption.client }.to raise_error(KmsEncryption::NotConfigured, /credentials/)
      end
    end
  end

  describe ".current_key_id" do
    it "is the key the alias points at, in the bare form stored beside each value, and makes one request" do
      KmsEncryption::Testing.isolated(source: :local, key_id: "alias/task-api-dev-data") do
        expect(KmsEncryption.current_key_id).to eq("local-task-api-dev-data")
        expect(KmsEncryption.client.count(:generate_data_key)).to eq(1)
      end
    end

    it "follows the alias when it is moved" do
      KmsEncryption::Testing.isolated(source: :local, key_id: "alias/task-api-dev-data") do |configuration|
        configuration.key_id = "alias/task-api-dev-data-2"
        expect(KmsEncryption.current_key_id).to eq("local-task-api-dev-data-2")
      end
    end
  end

  describe ".ready?" do
    it "is ready on the local stand-in" do
      KmsEncryption::Testing.isolated(source: :local) { expect(KmsEncryption.ready?).to be(true) }
    end

    it "is not ready with no source at all" do
      KmsEncryption::Testing.isolated(source: nil) { expect(KmsEncryption.ready?).to be(false) }
    end

    it "is ready on Rails' own keys only while it has them, since without them nothing can be encrypted" do
      KmsEncryption::Testing.isolated(source: :credentials) do
        allow(ActiveRecord::Encryption.config).to receive_messages(has_primary_key?: "k", has_deterministic_key?: "k")
        expect(KmsEncryption.ready?).to be(true)

        allow(ActiveRecord::Encryption.config).to receive(:has_deterministic_key?).and_return(nil)
        expect(KmsEncryption.ready?).to be(false)

        allow(ActiveRecord::Encryption.config).to receive_messages(has_primary_key?: nil, has_deterministic_key?: "k")
        expect(KmsEncryption.ready?).to be(false)
      end
    end

    it "is ready on KMS once the master unwraps, and not before" do
      KmsEncryption::Testing.isolated(source: :kms, key_id: "alias/task-api-dev-data") do |configuration|
        configuration.client = KmsEncryption::LocalClient.new
        expect(KmsEncryption.ready?).to be(false) # no wrapped master configured

        configuration.wrapped_deterministic_key = KmsEncryption.generate_wrapped_master
        expect(KmsEncryption.ready?).to be(true)
      end
    end

    it "is not ready while KMS is unreachable, and ready when it comes back" do
      KmsEncryption::Testing.isolated(source: :kms, key_id: "alias/task-api-dev-data") do |configuration|
        configuration.client = KmsEncryption::LocalClient.new
        configuration.wrapped_deterministic_key = KmsEncryption.generate_wrapped_master
        configuration.client = Class.new { def decrypt(**) = raise(KmsEncryption::Unavailable, "down") }.new
        expect(KmsEncryption.ready?).to be(false)

        configuration.client = KmsEncryption::LocalClient.new
        expect(KmsEncryption.ready?).to be(true)
      end
    end

    it "stays ready through a later KMS outage, because the master is in memory" do
      KmsEncryption::Testing.isolated(source: :kms, key_id: "alias/task-api-dev-data") do |configuration|
        configuration.client = KmsEncryption::LocalClient.new
        configuration.wrapped_deterministic_key = KmsEncryption.generate_wrapped_master
        expect(KmsEncryption.ready?).to be(true)

        configuration.client = Class.new { def decrypt(**) = raise(KmsEncryption::Unavailable, "down") }.new
        expect(KmsEncryption.ready?).to be(true)
      end
    end
  end
end
