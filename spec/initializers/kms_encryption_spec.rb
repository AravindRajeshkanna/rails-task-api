require "rails_helper"
require "kms_encryption/testing"

# config/initializers/kms_encryption.rb decides where the keys come from. Getting that wrong in production is silent (a public key, or no encryption),
# so each branch is pinned here by running the initializer against a made-up environment.
RSpec.describe "KMS encryption initializer" do
  def configure(env, rails_env: "production")
    KmsEncryption::Testing.isolated(source: nil) do |configuration|
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new(rails_env))
      stub_const("ENV", ENV.to_h.slice("PATH", "HOME").merge(env))
      load Rails.root.join("config/initializers/kms_encryption.rb")
      yield configuration
    end
  end

  it "uses KMS when a key is named, and takes the wrapped master and endpoint from the environment" do
    configure({ "KMS_KEY_ID" => "alias/task-api-prod-data", "KMS_WRAPPED_DETERMINISTIC_KEY" => "d3JhcHBlZA==", "KMS_ENDPOINT" => "https://vpce.example" }) do |config|
      expect(config).to have_attributes(source: :kms, key_id: "alias/task-api-prod-data", wrapped_deterministic_key: "d3JhcHBlZA==", endpoint: "https://vpce.example")
    end
  end

  it "reads the earlier masters of a rotation as a list, newest first, ignoring blanks" do
    configure({ "KMS_KEY_ID" => "alias/k", "KMS_PREVIOUS_WRAPPED_DETERMINISTIC_KEYS" => " bmV3ZXI= , b2xkZXI=,, " }) do |config|
      expect(config.previous_wrapped_deterministic_keys).to eq(%w[bmV3ZXI= b2xkZXI=])
    end
    configure({ "KMS_KEY_ID" => "alias/k" }) { |config| expect(config.previous_wrapped_deterministic_keys).to eq([]) }
  end

  it "uses Rails' own keys where it is told to (Kamal, docker compose)" do
    configure({ "ENCRYPTION_KEY_SOURCE" => "credentials" }) { |config| expect(config.source).to eq(:credentials) }
  end

  it "has no source at all in production when nothing is set, so it fails when used and /readyz fails, instead of encrypting with something it guessed" do
    configure({}) do |config|
      expect(config.source).to be_nil
      expect { KmsEncryption.client }.to raise_error(KmsEncryption::NotConfigured)
      expect(KmsEncryption.ready?).to be(false)
    end
  end

  it "refuses the public stand-in key in production, however it was asked for" do
    expect { configure({ "ENCRYPTION_KEY_SOURCE" => "local" }) { } }.to raise_error(/public key/)
  end

  it "uses the stand-in in development, with a key name of its own" do
    configure({}, rails_env: "development") { |config| expect(config).to have_attributes(source: :local, key_id: "alias/task-api-development-data") }
  end

  it "uses the stand-in in tests whatever the shell has exported, so a spec can never reach AWS" do
    configure({ "KMS_KEY_ID" => "alias/task-api-prod-data", "ENCRYPTION_KEY_SOURCE" => "kms" }, rails_env: "test") { |config| expect(config.source).to eq(:local) }
  end
end
