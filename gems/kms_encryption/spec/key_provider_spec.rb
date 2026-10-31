require "spec_helper"
require "kms_encryption"
require "kms_encryption/testing"

RSpec.describe KmsEncryption::KeyProvider do
  around { |example| KmsEncryption::Testing.isolated(source: :local, key_id: "alias/task-api-dev-data") { example.run } }

  let(:encryptor) { ActiveRecord::Encryption::Encryptor.new }
  let(:provider) { KmsEncryption.key_provider(table: "webhooks", attribute: "secret") }
  let(:client) { KmsEncryption.client }

  # The serializer Base64-encodes every string header.
  def header(ciphertext) = JSON.parse(ciphertext)["h"].transform_values { |value| Base64.strict_decode64(value) }

  it "encrypts with a data key KMS made, and keeps the wrapped copy and the id of the key that wrapped it in the value's own header" do
    ciphertext = encryptor.encrypt("whsec_123", key_provider: provider)

    expect(ciphertext).not_to include("whsec_123")
    expect(header(ciphertext)["i"]).to eq("kms:local-task-api-dev-data")
    expect(header(ciphertext)["k"]).to start_with("local-insecure:")
    expect(encryptor.decrypt(ciphertext, key_provider: provider)).to eq("whsec_123")
  end

  it "uses a different data key for every value" do
    first, second = Array.new(2) { encryptor.encrypt("same text", key_provider: provider) }

    expect(header(first)["k"]).not_to eq(header(second)["k"])
    expect(JSON.parse(first)["p"]).not_to eq(JSON.parse(second)["p"])
  end

  it "makes one KMS request to encrypt a value and none to read it back, because it keeps the key it just made" do
    ciphertext = encryptor.encrypt("whsec_123", key_provider: provider)
    encryptor.decrypt(ciphertext, key_provider: provider)

    expect(client.count(:generate_data_key)).to eq(1)
    expect(client.count(:decrypt)).to eq(0)
  end

  it "asks KMS to unwrap a key once, however often the value is read" do
    ciphertext = encryptor.encrypt("whsec_123", key_provider: provider)
    KmsEncryption.cache.clear # as in another process, or after the ttl

    50.times { encryptor.decrypt(ciphertext, key_provider: provider) }

    expect(client.count(:decrypt)).to eq(1)
  end

  it "asks once for each distinct value, since each has a key of its own" do
    ciphertexts = Array.new(20) { |index| encryptor.encrypt("value #{index}", key_provider: provider) }
    KmsEncryption.cache.clear

    2.times { ciphertexts.each { |ciphertext| encryptor.decrypt(ciphertext, key_provider: provider) } }

    expect(client.count(:decrypt)).to eq(20)
  end

  it "sends the application and the attribute as the encryption context" do
    ciphertext = encryptor.encrypt("whsec_123", key_provider: provider)
    KmsEncryption.cache.clear
    encryptor.decrypt(ciphertext, key_provider: provider)

    expect(client.requests.map(&:context)).to all(eq("app" => "task-api", "table" => "webhooks", "attribute" => "secret"))
  end

  it "does not unwrap a key copied from another attribute: the context is part of what KMS checks" do
    ciphertext = encryptor.encrypt("whsec_123", key_provider: provider)
    other = KmsEncryption.key_provider(table: "users", attribute: "name")

    expect { encryptor.decrypt(ciphertext, key_provider: other) }.to raise_error(KmsEncryption::InvalidCiphertext)
  end

  it "names the key on Decrypt, from the header rather than from the current setting, so rows made under an older key still read after a key change" do
    old = encryptor.encrypt("old", key_provider: provider)
    KmsEncryption.configuration.key_id = "alias/a-new-key"
    fresh = encryptor.encrypt("fresh", key_provider: provider)
    KmsEncryption.cache.clear
    client.reset!

    expect(encryptor.decrypt(old, key_provider: provider)).to eq("old")
    expect(encryptor.decrypt(fresh, key_provider: provider)).to eq("fresh")
    expect(client.requests.map(&:key_id)).to eq(%w[local-task-api-dev-data local-a-new-key])
  end

  it "says nothing is its own when the header is not one of its headers, which hands the value to the previous schemes" do
    foreign = ActiveRecord::Encryption::Message.new(payload: "x")
    foreign.headers.encrypted_data_key_id = "some-other-provider"

    expect(provider.decryption_keys(foreign)).to eq([])
    expect(provider.decryption_keys(ActiveRecord::Encryption::Message.new(payload: "x"))).to eq([])
  end

  it "reports a header that names a KMS key but holds no wrapped key as invalid ciphertext" do
    message = ActiveRecord::Encryption::Message.new(payload: "x")
    message.headers.encrypted_data_key_id = "kms:local-task-api-dev-data"

    expect { provider.decryption_keys(message) }.to raise_error(KmsEncryption::InvalidCiphertext, /no wrapped data key/)
  end

  it "needs the key id to encrypt, and says so" do
    KmsEncryption.configuration.key_id = nil

    expect { provider.encryption_key }.to raise_error(KmsEncryption::NotConfigured, /KMS_KEY_ID/)
  end

  describe "when KMS fails" do
    let(:down) do
      Class.new do
        def generate_data_key(**) = raise(KmsEncryption::Unavailable.new("down", reason: :network))
        def decrypt(**) = raise(KmsEncryption::Unavailable.new("down", reason: :network))
      end.new
    end

    it "raises Unavailable, which is not a decryption error: an outage must not look like corrupt data" do
      ciphertext = encryptor.encrypt("whsec_123", key_provider: provider)
      KmsEncryption.cache.clear
      KmsEncryption.configuration.client = down

      expect { encryptor.decrypt(ciphertext, key_provider: provider) }.to raise_error(KmsEncryption::Unavailable)
      expect { encryptor.encrypt("x", key_provider: provider) }.to raise_error(KmsEncryption::Unavailable)
      expect(KmsEncryption::Unavailable.ancestors).not_to include(ActiveRecord::Encryption::Errors::Base)
    end

    it "keeps serving what it already holds the key for" do
      ciphertext = encryptor.encrypt("whsec_123", key_provider: provider)
      encryptor.decrypt(ciphertext, key_provider: provider)
      KmsEncryption.configuration.client = down

      expect(encryptor.decrypt(ciphertext, key_provider: provider)).to eq("whsec_123")
    end
  end
end
