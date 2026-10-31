require "rails_helper"
require "rake"

# The operator's tools for the encryption keys (docs/runbooks/kms-key-rotation.md). They are how a column gets converted and how anyone learns it has been,
# so what they print and when they refuse is part of the procedure.
RSpec.describe "kms rake tasks" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("kms:status")
  end

  let(:legacy_provider) { ActiveRecord::Encryption::DerivedSecretKeyProvider.new(ActiveRecord::Encryption.config.primary_key) }

  def run(name, env = {})
    original = ENV.to_h.slice(*env.keys)
    env.each { |key, value| ENV[key] = value }
    Rake::Task[name].reenable
    output = StringIO.new
    $stdout = output
    $stderr = StringIO.new # abort prints its message here as well as raising it
    begin
      Rake::Task[name].invoke
    rescue SystemExit => error
      [ output.string, error.message ]
    else
      [ output.string, nil ]
    ensure
      $stdout = STDOUT
      $stderr = STDERR
      env.each_key { |key| original.key?(key) ? ENV[key] = original[key] : ENV.delete(key) }
    end
  end

  def write_secret(webhook, ciphertext)
    ActiveRecord::Base.connection.exec_update("UPDATE webhooks SET secret = $1 WHERE id = $2", "SQL", [ ciphertext, webhook.id ])
  end

  describe "kms:status" do
    it "prints what form every encrypted value is in and where the keys come from" do
      create(:webhook)

      printed, abort_message = run("kms:status")

      expect(printed).to match(/User\.email_address\s+encrypted: 1/)
      expect(printed).to match(/Webhook\.secret\s+kms:local-task-api-test-data: 1/)
      expect(printed).to include('source: :local, key: "alias/task-api-test-data"')
      expect(abort_message).to be_nil
    end

    it "only reports, by default, however much is left to convert" do
      write_secret(create(:webhook), ActiveRecord::Encryption::Encryptor.new.encrypt("old", key_provider: legacy_provider))

      printed, abort_message = run("kms:status")

      expect(printed).to match(/Webhook\.secret\s+rails_key: 1/)
      expect(abort_message).to be_nil
    end

    it "fails with STRICT=1 while anything is not yet under KMS, so a script can wait for the conversion before the credentials key is dropped" do
      write_secret(create(:webhook), ActiveRecord::Encryption::Encryptor.new.encrypt("old", key_provider: legacy_provider))

      _, abort_message = run("kms:status", "STRICT" => "1")

      expect(abort_message).to eq("Not under the current KMS key: Webhook.secret rails_key")
    end

    it "fails with STRICT=1 for values still under an older KMS key, so a key is not retired while it is in use" do
      create(:webhook)
      KmsEncryption.configuration.key_id = "alias/task-api-test-data-2"

      _, abort_message = run("kms:status", "STRICT" => "1")

      expect(abort_message).to eq("Not under the current KMS key: Webhook.secret kms:local-task-api-test-data")
    ensure
      KmsEncryption.configuration.key_id = "alias/task-api-test-data"
    end

    it "does not pretend to answer where the keys are Rails' own" do
      allow(KmsEncryption).to receive(:credentials?).and_return(true)

      _, abort_message = run("kms:status", "STRICT" => "1")

      expect(abort_message).to match(/no KMS key for values to be under/)
    end

    it "passes with STRICT=1 when everything is" do
      create(:webhook)

      expect(run("kms:status", "STRICT" => "1").last).to be_nil
    end
  end

  describe "kms:encrypt" do
    let!(:webhook) { create(:webhook) }

    before { write_secret(webhook, ActiveRecord::Encryption::Encryptor.new.encrypt("old", key_provider: legacy_provider)) }

    it "moves what is not yet under KMS and says how many" do
      printed, = run("kms:encrypt", "PAUSE" => "0")

      expect(printed).to include("1 values rewritten")
      expect(Webhook.find(webhook.id).secret).to eq("old")
      expect(EncryptionInventory.new.outstanding).to eq({})
    end

    it "moves values made under an older KMS key to the current one without being told to rewrap, which is how a rotation finishes" do
      run("kms:encrypt", "PAUSE" => "0")
      KmsEncryption.configuration.key_id = "alias/task-api-test-data-2"

      printed, = run("kms:encrypt", "PAUSE" => "0")

      expect(printed).to include("1 values rewritten") # the webhook; the deterministic addresses have no key to be under
      expect(EncryptionInventory.new.status["Webhook.secret"].keys).to eq([ "kms:local-task-api-test-data-2" ])
    ensure
      KmsEncryption.configuration.key_id = "alias/task-api-test-data"
    end

    it "re-encrypts everything with REWRAP=1, under whichever key new values are now made with" do
      run("kms:encrypt", "PAUSE" => "0")
      before = ActiveRecord::Base.connection.select_value("SELECT secret FROM webhooks WHERE id = #{webhook.id}")
      KmsEncryption.configuration.key_id = "alias/task-api-test-data-2"

      printed, = run("kms:encrypt", "PAUSE" => "0", "REWRAP" => "1")

      expect(printed).to match(/2 values rewritten/) # the project owner, who is encrypted like anyone, and the webhook
      expect(ActiveRecord::Base.connection.select_value("SELECT secret FROM webhooks WHERE id = #{webhook.id}")).not_to eq(before)
      expect(EncryptionInventory.new.status["Webhook.secret"].keys).to eq([ "kms:local-task-api-test-data-2" ])
    ensure
      KmsEncryption.configuration.key_id = "alias/task-api-test-data"
    end

    it "refuses where the keys are Rails' own, since there is no KMS key to move values to" do
      allow(KmsEncryption).to receive(:credentials?).and_return(true)

      _, abort_message = run("kms:encrypt")

      expect(abort_message).to match(/no KMS key/)
    end
  end

  describe "kms:verify" do
    it "says so when every value can be read" do
      create(:webhook)

      printed, abort_message = run("kms:verify")

      expect(printed).to include("Every encrypted value can be read.")
      expect(abort_message).to be_nil
    end

    it "fails, naming the values, when some cannot, so nothing is retired while it still matters" do
      webhook = create(:webhook)
      user = create(:user)
      ActiveRecord::Base.connection.exec_update("UPDATE users SET email_address = $1 WHERE id = $2", "SQL", [ "plain@example.com", user.id ])

      _, abort_message = run("kms:verify")

      expect(abort_message).to eq("Cannot be read: User.email_address ids #{user.id} (1)")
      expect(webhook).to be_persisted
    end
  end

  describe "kms:generate_wrapped_master" do
    it "prints only the wrapped form, once" do
      printed, = run("kms:generate_wrapped_master")

      wrapped = printed.strip
      expect(printed.lines.size).to eq(1)
      expect(Base64.strict_decode64(wrapped)).to start_with("local-insecure:")
      expect(KmsEncryption.client.decrypt(ciphertext_blob: Base64.strict_decode64(wrapped), context: KmsEncryption.master_context).bytesize).to eq(32)
    end
  end
end
