module KmsEncryption
  # For specs: run a block against a fresh configuration, key cache and master, then put the real ones back, so a spec can use a failing client or a
  # different key without leaking into the next one.
  #
  #   KmsEncryption::Testing.isolated(source: :local, key_id: "alias/test") { |config| ... }
  module Testing
    def self.isolated(source: :local, **settings)
      original = KmsEncryption.instance_variable_get(:@configuration)
      configuration = Configuration.new
      settings.each { |name, value| configuration.public_send("#{name}=", value) }
      configuration.source = source
      KmsEncryption.instance_variable_set(:@configuration, configuration)
      KmsEncryption.reset!
      yield configuration
    ensure
      KmsEncryption.instance_variable_set(:@configuration, original)
      KmsEncryption.reset!
    end
  end
end
