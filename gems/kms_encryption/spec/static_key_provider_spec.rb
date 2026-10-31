require "spec_helper"
require "kms_encryption"
require "kms_encryption/testing"

RSpec.describe KmsEncryption::StaticKeyProvider do
  around { |example| KmsEncryption::Testing.isolated(source: :local, key_id: "alias/task-api-dev-data") { example.run } }

  let(:encryptor) { ActiveRecord::Encryption::Encryptor.new }
  let(:email) { KmsEncryption.deterministic_key_provider(info: "users.email_address") }

  def encrypt(text, provider) = encryptor.encrypt(text, key_provider: provider, cipher_options: { deterministic: true })

  def decrypt(text, provider) = encryptor.decrypt(text, key_provider: provider)

  it "gives the same ciphertext for the same text, so a query can find it" do
    expect(encrypt("grace@example.com", email)).to eq(encrypt("grace@example.com", email))
    expect(encrypt("grace@example.com", email)).not_to eq(encrypt("ada@example.com", email))
    expect(decrypt(encrypt("grace@example.com", email), email)).to eq("grace@example.com")
  end

  it "derives a separate key for each attribute, so one address is not the same value in two tables" do
    invitations = KmsEncryption.deterministic_key_provider(info: "organization_invitations.email_address")

    expect(encrypt("grace@example.com", email)).not_to eq(encrypt("grace@example.com", invitations))
    expect(email.encryption_key.secret).not_to eq(invitations.encryption_key.secret)
  end

  it "is stable across processes, which is the point: the key comes from the wrapped master, not from chance" do
    other_process = KmsEncryption.deterministic_key_provider(info: "users.email_address")

    expect(encrypt("grace@example.com", other_process)).to eq(encrypt("grace@example.com", email))
  end

  describe "with a wrapped master" do
    let(:wrapped) { KmsEncryption.generate_wrapped_master }

    before { KmsEncryption.configuration.wrapped_deterministic_key = wrapped }

    it "unwraps the master once, on first use, and never again" do
      client = KmsEncryption.client
      client.reset!

      provider = KmsEncryption.deterministic_key_provider(info: "users.email_address")
      100.times { |index| encrypt("user#{index}@example.com", provider) }
      KmsEncryption.deterministic_key_provider(info: "other.attribute").encryption_key

      expect(client.count(:decrypt)).to eq(1)
    end

    it "does not need KMS to be up once it has the key" do
      provider = KmsEncryption.deterministic_key_provider(info: "users.email_address")
      ciphertext = encrypt("grace@example.com", provider)
      KmsEncryption.configuration.client = Class.new { def decrypt(**) = raise(KmsEncryption::Unavailable, "down") }.new

      expect(encrypt("grace@example.com", provider)).to eq(ciphertext)
    end

    it "does not remember a failed unwrap, so the next call tries again" do
      KmsEncryption.configuration.client = Class.new { def decrypt(**) = raise(KmsEncryption::Unavailable, "down") }.new
      provider = KmsEncryption.deterministic_key_provider(info: "users.email_address")

      expect { provider.encryption_key }.to raise_error(KmsEncryption::Unavailable)
      KmsEncryption.configuration.client = KmsEncryption::LocalClient.new
      expect { provider.encryption_key }.not_to raise_error
    end

    it "gives a different key from another master, and reads an older one through a previous provider" do
      older = KmsEncryption.deterministic_key_provider(info: "users.email_address")
      before_rotation = encrypt("grace@example.com", older)

      rotated = KmsEncryption.generate_wrapped_master
      KmsEncryption.configuration.wrapped_deterministic_key = rotated
      current = KmsEncryption.deterministic_key_provider(info: "users.email_address")
      previous = KmsEncryption.deterministic_key_provider(info: "users.email_address", wrapped_key: wrapped)

      expect(encrypt("grace@example.com", current)).not_to eq(before_rotation)
      expect(decrypt(before_rotation, previous)).to eq("grace@example.com")
    end
  end

  describe "the wrapped master" do
    it "is bound to the application and to its purpose, so it will not unwrap as any other kind of key" do
      wrapped = KmsEncryption.generate_wrapped_master

      expect { KmsEncryption.client.decrypt(ciphertext_blob: Base64.strict_decode64(wrapped), context: { "app" => "task-api" }) }.to raise_error(KmsEncryption::InvalidCiphertext)
      expect(KmsEncryption.master_context).to eq("app" => "task-api", "purpose" => "deterministic-master")
    end

    it "is never given back in plaintext" do
      wrapped = KmsEncryption.generate_wrapped_master

      expect(wrapped).to be_a(String)
      expect(Base64.strict_decode64(wrapped)).to start_with("local-insecure:")
    end

    it "must be configured outside development and test" do
      KmsEncryption.configuration.source = :kms
      KmsEncryption.configuration.client = KmsEncryption::LocalClient.new

      expect { KmsEncryption.deterministic_master }.to raise_error(KmsEncryption::NotConfigured, /KMS_WRAPPED_DETERMINISTIC_KEY/)
    end

    it "reports a value that is not base64 as invalid ciphertext" do
      KmsEncryption.configuration.wrapped_deterministic_key = "!!! not base64 !!!"

      expect { KmsEncryption.deterministic_master }.to raise_error(KmsEncryption::InvalidCiphertext, /base64/)
    end
  end
end
