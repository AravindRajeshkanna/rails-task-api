# What state every encrypted value is in, and the means to bring them all to the current one (ADR 69, docs/runbooks/kms-key-rotation.md). Reads the stored
# bytes, not the decrypted values, so it needs no KMS to say what is where. Behind `bin/rails kms:status` and `kms:encrypt`.
#
# A value is in one of these forms:
#   plaintext        never encrypted (the column existed before it was encrypted)
#   rails_key        encrypted with the key in the Rails credentials (before KMS); a non-deterministic attribute only, since a deterministic one carries
#                    no sign of which key made it
#   encrypted        a deterministic attribute: ciphertext, key not recorded
#   kms:<key id>     a value whose data key is wrapped by this KMS key
class EncryptionInventory
  Target = Struct.new(:model, :name) do
    def label = "#{model.name}.#{name}"
    def deterministic? = model.type_for_attribute(name).scheme.deterministic?
    def column = model.connection.quote_column_name(model.attribute_alias?(name) ? model.attribute_alias(name) : name)
    def table = model.connection.quote_table_name(model.table_name)
  end

  # Cap on how many rows one call reads at once.
  BATCH = 500

  def self.targets
    Rails.application.eager_load! unless Rails.application.config.eager_load
    # Only models that are constants: a class made on the fly (a spec's, say) is not part of the application and lives as long as the garbage collector lets it.
    ApplicationRecord.descendants.reject(&:abstract_class?).select { |model| model.name.safe_constantize.equal?(model) }.flat_map do |model|
      (model.try(:encrypted_attributes) || []).map { |name| Target.new(model, name.to_s) }
    end.sort_by(&:label)
  end

  # { "User.email_address" => { "encrypted" => 41, "plaintext" => 2 }, ... }
  def status
    self.class.targets.to_h { |target| [ target.label, tally(target) ] }
  end

  # The forms that are not the current one, per attribute. Empty when everything is encrypted the way new values are.
  def outstanding(current_key_id: nil)
    status.transform_values { |forms| forms.reject { |form, _| current?(form, current_key_id) } }.reject { |_, forms| forms.empty? }
  end

  # Reads every encrypted value through the current configuration and returns the ones that do not decrypt: { "User.email_address" => [ids] }. The answer to
  # "can everything still be read with only what is configured now?", which is the question before an old key or master is retired. A value is read, not
  # changed, and a KMS outage raises (that is not a verdict on the value).
  def verify(output: nil)
    self.class.targets.to_h do |target|
      unreadable = []
      each_row(target) do |rows|
        target.model.where(id: rows.map(&:first)).find_each do |record|
          record.public_send(target.name)
        rescue ActiveRecord::Encryption::Errors::Base, KmsEncryption::InvalidCiphertext
          unreadable << record.id
        end
        output&.puts("#{target.label}: checked through id #{rows.last.first}")
      end
      [ target.label, unreadable ]
    end.reject { |_, ids| ids.empty? }
  end

  # Brings values to the current form by re-saving them through their own encryption: plaintext and Rails-keyed values are encrypted; with rewrap: every
  # value is, which is how data moves to a new key. Safe to repeat and to interrupt (a value is read, then written once). Returns the number rewritten.
  def encrypt!(rewrap: false, pause: 0, current_key_id: nil, output: nil)
    self.class.targets.sum do |target|
      rewritten = 0
      each_row(target) do |ids_and_raw|
        stale = ids_and_raw.reject { |_, raw| !rewrap && current?(form_of(raw, target), current_key_id) }.map(&:first)
        target.model.where(id: stale).find_each do |record|
          record.encrypt
          rewritten += 1
        end
        output&.puts("#{target.label}: #{rewritten} rewritten (through id #{ids_and_raw.last.first})")
        sleep(pause) if pause.positive?
      end
      rewritten
    end
  end

  def form_of(raw, target)
    return "plaintext" unless raw.start_with?('{"p":')

    reference = header(raw, "i")
    return "encrypted" if target.deterministic?

    reference&.start_with?(KmsEncryption::KeyProvider::HEADER_PREFIX) ? reference : "rails_key"
  end

  private
    # "Current" for a KMS value means made under the key new values are made under (when we know which that is); a deterministic value is current when it
    # is ciphertext at all. Plaintext and Rails-keyed values never are.
    def current?(form, current_key_id)
      case form
      when "encrypted" then true
      when "plaintext", "rails_key" then false
      else current_key_id.nil? || form == "#{KmsEncryption::KeyProvider::HEADER_PREFIX}#{current_key_id}"
      end
    end

    def tally(target)
      counts = Hash.new(0)
      each_row(target) { |rows| rows.each { |_, raw| counts[form_of(raw, target)] += 1 } }
      counts.sort.to_h
    end

    # Keyset paging over the raw column, so nothing is decrypted and a large table is read in pieces.
    def each_row(target)
      last = 0
      loop do
        rows = target.model.connection.select_rows(
          "SELECT id, #{target.column} FROM #{target.table} WHERE id > #{last.to_i} AND #{target.column} IS NOT NULL ORDER BY id LIMIT #{BATCH}"
        )
        break if rows.empty?

        yield rows.map { |id, raw| [ id.to_i, raw.to_s ] }
        last = rows.last.first.to_i
      end
    end

    # Rails Base64-encodes every string header when it serialises a message.
    def header(raw, name)
      value = JSON.parse(raw).dig("h", name)
      value && Base64.decode64(value)
    rescue JSON::ParserError
      nil
    end
end
