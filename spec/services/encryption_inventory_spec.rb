require "rails_helper"

RSpec.describe EncryptionInventory do
  let(:inventory) { described_class.new }
  let(:client) { KmsEncryption.client }
  let(:legacy_provider) { ActiveRecord::Encryption::DerivedSecretKeyProvider.new(ActiveRecord::Encryption.config.primary_key) }

  def write_raw(table, id, value)
    ActiveRecord::Base.connection.exec_update("UPDATE #{table} SET #{table == 'users' ? 'email_address' : 'secret'} = $1 WHERE id = $2", "SQL", [ value, id ])
  end

  def stored(table, id) = ActiveRecord::Base.connection.select_value("SELECT #{table == 'users' ? 'email_address' : 'secret'} FROM #{table} WHERE id = #{id}")

  def legacy_secret(text) = ActiveRecord::Encryption::Encryptor.new.encrypt(text, key_provider: legacy_provider)

  # Some examples change the key id new values are made under; none may leave it changed.
  around do |example|
    original = KmsEncryption.configuration.key_id
    example.run
  ensure
    KmsEncryption.configuration.key_id = original
  end

  let!(:webhook) { create(:webhook) }
  let!(:user) { create(:user, email_address: "grace@example.com") }
  let(:owner) { webhook.project.owner } # the factory chain makes one more user, who is encrypted like any other
  let(:local_key) { "kms:local-#{KmsEncryption.configuration.key_id.split('/').last}" }

  describe "#status" do
    it "says what form every value is in, from the stored bytes" do
      status = inventory.status

      expect(status.keys).to eq(%w[User.email_address Webhook.secret])
      expect(status["User.email_address"]).to eq("encrypted" => 2)
      expect(status["Webhook.secret"]).to eq(local_key => 1)
    end

    it "tells plaintext and Rails-keyed values apart from KMS ones" do
      write_raw("users", user.id, "grace@example.com")
      write_raw("webhooks", webhook.id, legacy_secret("old"))

      expect(inventory.status).to eq("User.email_address" => { "encrypted" => 1, "plaintext" => 1 }, "Webhook.secret" => { "rails_key" => 1 })
    end

    it "needs no KMS to say so" do
      client.reset!
      inventory.status

      expect(client.requests).to be_empty
    end

    it "skips empty values and counts nothing for an empty table" do
      Webhook.delete_all

      expect(inventory.status["Webhook.secret"]).to eq({})
    end

    it "reads a large table in pieces" do
      stub_const("EncryptionInventory::BATCH", 2)
      create_list(:user, 5)

      expect(inventory.status["User.email_address"]).to eq("encrypted" => 7)
    end
  end

  describe ".targets" do
    it "are the application's models, not a class made on the fly, which would otherwise be counted for as long as it stays in memory" do
      Class.new(ApplicationRecord) do
        self.table_name = "webhooks"
        def self.name = "SomethingMadeInASpec"
        encrypts_with_kms :secret
      end

      expect(described_class.targets.map(&:label)).to eq(%w[User.email_address Webhook.secret])
    end
  end

  describe "#verify" do
    it "has nothing to report when every value reads with what is configured now" do
      expect(inventory.verify).to eq({})
    end

    it "names the values that do not, per attribute, without raising" do
      # A secret whose wrapped key was made for another attribute: KMS refuses to unwrap it for this one.
      copied = ActiveRecord::Encryption::Encryptor.new.encrypt("stolen", key_provider: KmsEncryption.key_provider(table: "users", attribute: "name"))
      write_raw("webhooks", webhook.id, copied)
      other = create(:user)
      write_raw("users", other.id, "someone@example.com") # plaintext in an encrypted column

      expect(inventory.verify).to eq("User.email_address" => [ other.id ], "Webhook.secret" => [ webhook.id ])
    end

    it "does not take a KMS outage for a verdict on the data: it raises" do
      KmsEncryption.cache.clear
      down = Class.new { def decrypt(**) = raise(KmsEncryption::Unavailable, "down") }.new
      allow(KmsEncryption.configuration).to receive(:client).and_return(down)

      expect { inventory.verify }.to raise_error(KmsEncryption::Unavailable)
    end

    it "reports progress when asked" do
      output = StringIO.new

      inventory.verify(output: output)

      expect(output.string).to match(/User\.email_address: checked through id/).and match(/Webhook\.secret: checked through id/)
    end
  end

  describe "#outstanding" do
    it "is empty when everything is encrypted the way new values are" do
      expect(inventory.outstanding).to eq({})
    end

    it "lists what is not, so an operator can tell when it is safe to drop the credentials key" do
      write_raw("webhooks", webhook.id, legacy_secret("old"))

      expect(inventory.outstanding).to eq("Webhook.secret" => { "rails_key" => 1 })
    end

    it "counts a value under another KMS key as outstanding once the current key is known" do
      expect(inventory.outstanding(current_key_id: "local-some-newer-key")).to eq("Webhook.secret" => { local_key => 1 })
      expect(inventory.outstanding(current_key_id: local_key.delete_prefix("kms:"))).to eq({})
    end
  end

  describe "#encrypt!" do
    before do
      write_raw("users", user.id, "grace@example.com")
      write_raw("webhooks", webhook.id, legacy_secret("whsec_old"))
      allow(ActiveRecord::Encryption.config).to receive(:support_unencrypted_data).and_return(true)
    end

    it "encrypts plaintext and moves Rails-keyed values to KMS, and the values read back the same" do
      expect(inventory.encrypt!).to eq(2)

      expect(inventory.outstanding).to eq({})
      expect(User.find(user.id).email_address).to eq("grace@example.com")
      expect(Webhook.find(webhook.id).secret).to eq("whsec_old")
    end

    it "does nothing the second time, and touches no value that is already current" do
      inventory.encrypt!
      before = stored("webhooks", webhook.id)

      expect(inventory.encrypt!).to eq(0)
      expect(stored("webhooks", webhook.id)).to eq(before)
    end

    it "leaves updated_at alone: encrypting a value is not an edit" do
      expect { inventory.encrypt! }.not_to change { User.find(user.id).updated_at }
    end

    it "reports progress and can pause between batches" do
      output = StringIO.new
      stub_const("EncryptionInventory::BATCH", 1)
      allow(inventory).to receive(:sleep)

      inventory.encrypt!(pause: 0.5, output: output)

      expect(output.string).to match(/User\.email_address: 1 rewritten \(through id #{user.id}\)/)
      expect(inventory).to have_received(:sleep).with(0.5).at_least(:once)
    end

    it "re-encrypts everything when asked to rewrap, which is how data moves to a new key" do
      inventory.encrypt!
      secret_before = stored("webhooks", webhook.id)
      email_before = stored("users", user.id)

      expect(inventory.encrypt!(rewrap: true)).to eq(3) # both users and the webhook

      expect(stored("webhooks", webhook.id)).not_to eq(secret_before) # a new data key, a new ciphertext
      expect(stored("users", user.id)).to eq(email_before)            # deterministic: the same text under the same key is the same bytes
      expect(Webhook.find(webhook.id).secret).to eq("whsec_old")
    end

    it "moves a value made under an older KMS key to the current one" do
      inventory.encrypt!
      old_id = local_key.delete_prefix("kms:")
      KmsEncryption.configuration.key_id = "alias/task-api-test-data-2"
      new_id = "local-task-api-test-data-2"

      expect(inventory.outstanding(current_key_id: new_id)).to eq("Webhook.secret" => { "kms:#{old_id}" => 1 })
      expect(inventory.encrypt!(current_key_id: new_id)).to eq(1)

      expect(inventory.outstanding(current_key_id: new_id)).to eq({})
      expect(Webhook.find(webhook.id).secret).to eq("whsec_old")
    end
  end
end
