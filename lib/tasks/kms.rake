# Operating the encryption keys: docs/runbooks/kms-key-rotation.md.
namespace :kms do
  desc "Which form every encrypted value is in (plaintext, Rails key, KMS key id). STRICT=1 exits 1 while any is not under the KMS key new values use"
  task status: :environment do
    inventory = EncryptionInventory.new
    report = inventory.status
    width = report.keys.map(&:length).max.to_i
    report.each do |label, forms|
      puts "#{label.ljust(width)}  #{forms.empty? ? 'no values' : forms.map { |form, count| "#{form}: #{count}" }.join(', ')}"
    end
    puts "source: #{KmsEncryption.configuration.source.inspect}, key: #{KmsEncryption.configuration.key_id.inspect}"
    next unless ENV["STRICT"] == "1"

    abort "ENCRYPTION_KEY_SOURCE=credentials: the keys are Rails' own, and there is no KMS key for values to be under." if KmsEncryption.credentials?

    # Asks KMS which key new values are made under now (one request), so that values under an older key count as outstanding.
    outstanding = inventory.outstanding(current_key_id: KmsEncryption.current_key_id)
    abort "Not under the current KMS key: #{outstanding.map { |label, forms| "#{label} #{forms.keys.join('/')}" }.join('; ')}" if outstanding.any?
  end

  desc "Encrypt what is not under the current key: plaintext, values under the Rails key, values under an older KMS key. REWRAP=1 re-encrypts everything. PAUSE=0.1 seconds between batches"
  task encrypt: :environment do
    abort "ENCRYPTION_KEY_SOURCE=credentials: the keys are Rails' own, and there is no KMS key to move values to." if KmsEncryption.credentials?

    rewritten = EncryptionInventory.new.encrypt!(rewrap: ENV["REWRAP"] == "1", current_key_id: KmsEncryption.current_key_id, pause: ENV.fetch("PAUSE", "0.1").to_f, output: $stdout)
    puts "#{rewritten} values rewritten. Check with: bin/rails kms:status"
  end

  desc "Read every encrypted value with only the current configuration; exits 1 listing the ones that cannot be read (run before retiring a key or master)"
  task verify: :environment do
    unreadable = EncryptionInventory.new.verify(output: $stdout)
    abort "Cannot be read: #{unreadable.map { |label, ids| "#{label} ids #{ids.first(20).join(', ')}#{' ...' if ids.size > 20} (#{ids.size})" }.join('; ')}" if unreadable.any?

    puts "Every encrypted value can be read."
  end

  desc "A new wrapped master secret for deterministic attributes: store it as KMS_WRAPPED_DETERMINISTIC_KEY. Prints the wrapped form only"
  task generate_wrapped_master: :environment do
    puts KmsEncryption.generate_wrapped_master
  end
end
