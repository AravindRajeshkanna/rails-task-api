require "rails_helper"

# The workaround in config/initializers/encryption_transition.rb for Rails' extended queries on a normalized attribute. If this fails after a Rails upgrade,
# either Rails fixed the problem (delete the initializer) or moved the pieces it relies on (fix it).
RSpec.describe "Encryption transition workaround" do
  let(:additional_value) { ActiveRecord::Encryption::ExtendedDeterministicQueries::AdditionalValue }
  let(:model) do
    ActiveRecord::Base.connection.create_table(:transition_probes, temporary: true) { |table| table.string :address }
    Class.new(ApplicationRecord) do
      self.table_name = "transition_probes"
      def self.name = "TransitionProbe"
      encrypts_with_kms :address, deterministic: true
      normalizes :address, with: ->(address) { address.strip.downcase }
    end
  end
  let(:type) { model.type_for_attribute("address") }

  before do
    allow(ActiveRecord::Encryption.config).to receive(:support_unencrypted_data).and_return(true)
    stub_const("ENV", ENV.to_h.merge("ENCRYPTION_ALLOW_PLAINTEXT" => "true"))
    load Rails.root.join("config/initializers/encryption_transition.rb")
    # What ExtendedDeterministicQueries.install_support does for every encrypted type when extend_queries is on at boot; here for this one type only.
    type.__getobj__.singleton_class.prepend(ActiveRecord::Encryption::ExtendedDeterministicQueries::ExtendedEncryptableType)
  end

  it "turns the plaintext alternative of a query into the normalized plaintext, which is what a not-yet-converted row holds" do
    alternative = additional_value.new(" Grace@Example.COM ", type.previous_types.first)

    expect(type.serialize(alternative)).to eq("grace@example.com")
  end

  it "leaves the encrypted form of the same query encrypted and normalized, so converted rows still match" do
    encrypted = type.serialize(" Grace@Example.COM ")

    expect(encrypted).to start_with('{"p":')
    expect(encrypted).to eq(type.serialize("grace@example.com"))
  end

  it "does not touch an alternative that is itself a ciphertext (a previous scheme's), whose letter case matters" do
    previous = ActiveRecord::Encryption::Encryptor.new.encrypt("grace@example.com", key_provider: ActiveRecord::Encryption::DerivedSecretKeyProvider.new(ActiveRecord::Encryption.config.primary_key))
    wrapped = additional_value.new("grace@example.com", type.previous_types.first)
    allow(wrapped).to receive(:value).and_return(previous)

    expect(type.serialize(wrapped)).to eq(previous)
  end
end
