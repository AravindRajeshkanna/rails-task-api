require "spec_helper"
require "kms_encryption"

RSpec.describe KmsEncryption::LocalClient do
  let(:client) { described_class.new }
  let(:context) { { "app" => "task-api", "attribute" => "secret" } }

  it "wraps a data key and unwraps it again" do
    data_key = client.generate_data_key(key_id: "alias/dev-data", context: context)

    expect(data_key.plaintext.bytesize).to eq(32)
    expect(data_key.ciphertext).not_to include(data_key.plaintext)
    expect(client.decrypt(ciphertext_blob: data_key.ciphertext, key_id: data_key.key_id, context: context)).to eq(data_key.plaintext)
  end

  it "reports the bare key id an alias resolves to, as KMS reports the key rather than the alias" do
    expect(client.generate_data_key(key_id: "alias/dev-data", context: context).key_id).to eq("local-dev-data")
  end

  it "needs the same encryption context to unwrap, as KMS does" do
    data_key = client.generate_data_key(key_id: "alias/dev-data", context: context)

    expect { client.decrypt(ciphertext_blob: data_key.ciphertext, context: context.merge("attribute" => "other")) }.to raise_error(KmsEncryption::InvalidCiphertext)
    expect { client.decrypt(ciphertext_blob: data_key.ciphertext, context: {}) }.to raise_error(KmsEncryption::InvalidCiphertext)
  end

  it "refuses to unwrap under a key other than the one that wrapped it, and works when no key is named" do
    data_key = client.generate_data_key(key_id: "alias/dev-data", context: context)

    expect { client.decrypt(ciphertext_blob: data_key.ciphertext, key_id: "alias/another-key", context: context) }.to raise_error(KmsEncryption::InvalidCiphertext)
    expect(client.decrypt(ciphertext_blob: data_key.ciphertext, context: context)).to eq(data_key.plaintext)
  end

  it "rejects bytes it did not make, and tampered ones" do
    data_key = client.generate_data_key(key_id: "alias/dev-data", context: context)
    tampered = data_key.ciphertext.dup.tap { |blob| blob.setbyte(-1, blob.getbyte(-1) ^ 1) }

    expect { client.decrypt(ciphertext_blob: "garbage", context: context) }.to raise_error(KmsEncryption::InvalidCiphertext)
    expect { client.decrypt(ciphertext_blob: tampered, context: context) }.to raise_error(KmsEncryption::InvalidCiphertext)
  end

  it "counts what it was asked, so a spec can pin how many KMS requests an operation makes" do
    data_key = client.generate_data_key(key_id: "alias/dev-data", context: context)
    2.times { client.decrypt(ciphertext_blob: data_key.ciphertext, context: context) }

    expect(client.count(:generate_data_key)).to eq(1)
    expect(client.count(:decrypt)).to eq(2)
    client.reset!
    expect(client.requests).to be_empty
  end
end
