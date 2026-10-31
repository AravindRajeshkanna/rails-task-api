require "rails_helper"
require "kms_encryption/testing"

# What encrypting with keys that KMS protects must mean in this application (ADR 69): the database holds ciphertext, the code sees plaintext, an address can
# still be found by equality, no attribute quietly uses a different key, and the paths a request takes all the time make no KMS request.
RSpec.describe "Encrypted attributes" do
  let(:client) { KmsEncryption.client }

  def stored(table, column, id) = ActiveRecord::Base.connection.select_value("SELECT #{column} FROM #{table} WHERE id = #{id.to_i}")

  def header(raw, name) = Base64.decode64(JSON.parse(raw).dig("h", name).to_s)

  def write_raw(table, column, id, value)
    ActiveRecord::Base.connection.exec_update("UPDATE #{table} SET #{column} = $1 WHERE id = $2", "SQL", [ value, id ])
  end

  describe "at rest" do
    it "stores an email address as ciphertext and gives it back as text" do
      user = create(:user, email_address: "grace@example.com")

      raw = stored("users", "email_address", user.id)
      expect(raw).to start_with('{"p":')
      expect(raw).not_to include("grace", "example.com")
      expect(User.find(user.id).email_address).to eq("grace@example.com")
    end

    it "stores a webhook secret as ciphertext whose data key is wrapped by KMS, and gives it back" do
      webhook = create(:webhook)

      raw = stored("webhooks", "secret", webhook.id)
      expect(raw).not_to include(webhook.secret)
      expect(header(raw, "i")).to start_with("kms:")
      expect(header(raw, "k")).to be_present
      expect(Webhook.find(webhook.id).secret).to eq(webhook.secret)
    end

    it "keeps plaintext out of the queries it sends, not just out of the rows" do
      create(:user, email_address: "grace@example.com")
      sent = []
      subscription = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| sent << [ payload[:sql], payload[:type_casted_binds].to_s ] }

      User.find_by(email_address: "grace@example.com")

      ActiveSupport::Notifications.unsubscribe(subscription)
      expect(sent.flatten.join).not_to include("grace@example.com")
    end

    it "hides encrypted values when a record is inspected or logged" do
      user = create(:user, email_address: "grace@example.com")

      expect(user.inspect).not_to include("grace@example.com")
      expect(create(:webhook).inspect).not_to match(/secret: "[0-9a-f]{20}/)
    end
  end

  describe "finding by an encrypted address" do
    let!(:user) { create(:user, email_address: "grace@example.com") }

    it "still works for equality, with the address normalized as before" do
      expect(User.find_by(email_address: "grace@example.com")).to eq(user)
      expect(User.find_by(email_address: "  Grace@Example.COM ")).to eq(user)
      expect(User.where(email_address: %w[grace@example.com nobody@example.com])).to contain_exactly(user)
      expect(User.find_by(email_address: "nobody@example.com")).to be_nil
    end

    it "still signs in by address and password" do
      expect(User.authenticate_by(email_address: "grace@example.com", password: "correct-horse-battery")).to eq(user)
      expect(User.authenticate_by(email_address: "grace@example.com", password: "wrong")).to be_nil
    end

    it "gives the same address the same ciphertext, so the unique index still refuses a second account" do
      duplicate = build(:user, email_address: "grace@example.com")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:email_address]).to include("has already been taken")
      expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "gives different addresses different ciphertexts" do
      other = create(:user, email_address: "ada@example.com")

      expect(stored("users", "email_address", other.id)).not_to eq(stored("users", "email_address", user.id))
    end
  end

  describe "every encrypted attribute" do
    let(:targets) { EncryptionInventory.targets }

    it "is the ones we know about, so a new one is a decision somebody made" do
      expect(targets.map(&:label)).to eq(%w[User.email_address Webhook.secret])
    end

    it "takes its key from KMS and not from the Rails credentials, which is the point of the exercise" do
      targets.each do |target|
        provider = target.model.type_for_attribute(target.name).scheme.key_provider
        expected = target.deterministic? ? KmsEncryption::StaticKeyProvider : KmsEncryption::KeyProvider
        expect(provider).to be_a(expected), "#{target.label} uses #{provider.class}, not #{expected}"
      end
    end
  end

  describe "values written before KMS" do
    let(:legacy_provider) { ActiveRecord::Encryption::DerivedSecretKeyProvider.new(ActiveRecord::Encryption.config.primary_key) }
    let(:webhook) { create(:webhook) }

    before do
      legacy = ActiveRecord::Encryption::Encryptor.new.encrypt("whsec_from_before_kms", key_provider: legacy_provider)
      write_raw("webhooks", "secret", webhook.id, legacy)
    end

    it "encrypted with the credentials key still reads, so switching to KMS needs no downtime" do
      expect(Webhook.find(webhook.id).secret).to eq("whsec_from_before_kms")
    end

    it "moves to KMS when it is encrypted again, and stays readable" do
      Webhook.find(webhook.id).encrypt

      raw = stored("webhooks", "secret", webhook.id)
      expect(header(raw, "i")).to start_with("kms:")
      expect(Webhook.find(webhook.id).secret).to eq("whsec_from_before_kms")
    end
  end

  describe "once the credentials key has been removed, which is the end of the migration" do
    it "no longer offers the fallback, and defining a model no longer needs the key" do
      allow(ActiveRecord::Encryption.config).to receive(:has_primary_key?).and_return(nil)

      model = Class.new(ApplicationRecord) do
        self.table_name = "webhooks"
        def self.name = "WebhookWithoutTheCredentialsKey"
        encrypts_with_kms :secret, legacy_credentials: true
      end

      expect(model.type_for_attribute("secret").scheme.previous_schemes).to be_empty
    end

    it "still offers it while the credentials key is there" do
      expect(Webhook.type_for_attribute("secret").scheme.previous_schemes.size).to eq(1)
    end
  end

  describe "the encryption context" do
    it "names the application, the table and the attribute, which is what CloudTrail records and what an IAM condition can require" do
      webhook = create(:webhook)
      KmsEncryption.cache.clear
      client.reset!

      Webhook.find(webhook.id).secret

      expect(client.requests.map(&:context)).to eq([ { "app" => "task-api", "table" => "webhooks", "attribute" => "secret" } ])
    end
  end

  describe "deterministic attributes" do
    it "each get a key of their own, so the same text in two columns is two different values" do
      ActiveRecord::Base.connection.create_table(:other_addresses, temporary: true) { |table| table.string :address }
      other = Class.new(ApplicationRecord) do
        self.table_name = "other_addresses"
        def self.name = "OtherAddress"
        encrypts_with_kms :address, deterministic: true
      end

      ours = User.type_for_attribute("email_address").scheme.key_provider.encryption_key.secret
      theirs = other.type_for_attribute("address").scheme.key_provider.encryption_key.secret

      expect(ours).not_to eq(theirs)
      expect(other.create!(address: "grace@example.com").read_attribute_before_type_cast("address"))
        .not_to eq(create(:user, email_address: "grace@example.com").read_attribute_before_type_cast("email_address"))
    end
  end

  describe "rotating the master that deterministic keys derive from" do
    def address_model
      Class.new(ApplicationRecord) do
        self.table_name = "rotation_probes"
        def self.name = "RotationProbe"
        encrypts_with_kms :address, deterministic: true
      end
    end

    it "keeps old addresses readable through the previous master, moves them with encrypt, and lets the old master go once none is left" do
      ActiveRecord::Base.connection.create_table(:rotation_probes, temporary: true) { |table| table.string :address }

      KmsEncryption::Testing.isolated(source: :local, key_id: "alias/task-api-test-data") do |configuration|
        old_master = KmsEncryption.generate_wrapped_master
        configuration.wrapped_deterministic_key = old_master
        row = address_model.create!(address: "grace@example.com")
        written_under_old = stored("rotation_probes", "address", row.id)

        configuration.wrapped_deterministic_key = KmsEncryption.generate_wrapped_master
        configuration.previous_wrapped_deterministic_keys = [ old_master ]
        expect(address_model.find(row.id).address).to eq("grace@example.com") # read through the previous master
        address_model.find(row.id).encrypt
        written_under_new = stored("rotation_probes", "address", row.id)
        expect(written_under_new).not_to eq(written_under_old)

        configuration.previous_wrapped_deterministic_keys = [] # the old master is let go
        expect(address_model.find(row.id).address).to eq("grace@example.com")
      end
    end

    it "cannot read what is still under a master that has been let go, which is what verify is for" do
      ActiveRecord::Base.connection.create_table(:rotation_probes, temporary: true) { |table| table.string :address }

      KmsEncryption::Testing.isolated(source: :local, key_id: "alias/task-api-test-data") do |configuration|
        configuration.wrapped_deterministic_key = KmsEncryption.generate_wrapped_master
        row = address_model.create!(address: "grace@example.com")

        configuration.wrapped_deterministic_key = KmsEncryption.generate_wrapped_master # rotated, and the old one not kept
        expect { address_model.find(row.id).address }.to raise_error(ActiveRecord::Encryption::Errors::Decryption)
      end
    end
  end

  describe "plaintext in an encrypted column" do
    let(:user) { create(:user, email_address: "grace@example.com") }

    before { write_raw("users", "email_address", user.id, "grace@example.com") }

    it "is refused by default: a deployment that never had plaintext wants to hear about it" do
      expect { User.find(user.id).email_address }.to raise_error(ActiveRecord::Encryption::Errors::Decryption)
    end

    it "is read, and encrypted by encrypt, while a column is being converted (ENCRYPTION_ALLOW_PLAINTEXT)" do
      allow(ActiveRecord::Encryption.config).to receive(:support_unencrypted_data).and_return(true)

      expect(User.find(user.id).email_address).to eq("grace@example.com")
      User.find(user.id).encrypt
      expect(stored("users", "email_address", user.id)).to start_with('{"p":')
    end
  end

  describe "how often KMS is asked" do
    it "is not asked at all to find or sign in a user: the key is in memory" do
      user = create(:user, email_address: "grace@example.com")
      client.reset!

      5.times do
        User.find_by(email_address: "grace@example.com")
        User.authenticate_by(email_address: "grace@example.com", password: "correct-horse-battery")
        create(:user)
      end

      expect(client.requests).to be_empty
      expect(user).to be_persisted
    end

    it "is asked once to make a webhook's key, and once to unwrap it however often the secret is read or the record is saved" do
      client.reset!
      webhook = create(:webhook)
      expect(client.count(:generate_data_key)).to eq(1)
      expect(client.count(:decrypt)).to eq(0) # Rails reads back what it wrote; the key it just made is remembered

      KmsEncryption.cache.clear # as in another process
      found = Webhook.find(webhook.id)
      3.times { found.secret }
      found.update!(url: "https://hooks.example.com/other") # saving a record whose secret was read re-checks it for changes
      Webhook.find(webhook.id).secret

      expect(client.count(:decrypt)).to eq(1)
    end

    it "is asked once for each webhook when many are read, which is the most it ever costs" do
      project = create(:project)
      create_list(:webhook, 6, project: project)
      KmsEncryption.cache.clear
      client.reset!

      2.times { Webhook.where(project: project).map(&:secret) }

      expect(client.count(:decrypt)).to eq(6)
    end
  end
end
