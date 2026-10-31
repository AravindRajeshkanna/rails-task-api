class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  # Where a replica is configured (production with DB_REPLICA_HOST; development and test always, pointing at the same database) there is a reading role
  # that ReplicaRouting can switch a request to. Without one, none of that exists and every read goes to the primary.
  connects_to database: { writing: :primary, reading: :primary_replica } if ActiveRecord::Base.configurations.configs_for(env_name: Rails.env, name: "primary_replica", include_hidden: true)

  # Encrypts attributes with keys that AWS KMS protects (ADR 69). Use this, not `encrypts`: plain `encrypts` falls back to the key in the Rails credentials,
  # and spec/models/encryption_spec.rb fails when a model does.
  #
  #   encrypts_with_kms :secret                                          each value has a data key of its own, wrapped by KMS
  #   encrypts_with_kms :email_address, deterministic: true              one key per attribute, so `where(email_address: ...)` still finds it
  #   encrypts_with_kms :secret, legacy_credentials: true                values written before KMS were encrypted with the credentials key: still readable
  #
  # Where the keys are not on AWS (ENCRYPTION_KEY_SOURCE=credentials) this is `encrypts` with Rails' own keys.
  def self.encrypts_with_kms(*names, deterministic: false, legacy_credentials: false, **options)
    names.each do |name|
      if KmsEncryption.credentials?
        encrypts name, deterministic: deterministic, **options
      else
        provider = deterministic ? KmsEncryption.deterministic_key_provider(info: "#{table_name}.#{name}") : KmsEncryption.key_provider(table: table_name, attribute: name)
        # The credentials key stops mattering once no row is left under it (kms:status says when) and is removed from the credentials; the fallback goes with it.
        previous = legacy_credentials && ActiveRecord::Encryption.config.has_primary_key? ? [ { key_provider: ActiveRecord::Encryption::DerivedSecretKeyProvider.new(ActiveRecord::Encryption.config.primary_key) } ] : []
        # Deterministic values written under an earlier master stay readable (and found by queries) while a rotation moves them. By default Rails keeps
        # writing a deterministic attribute with its OLDEST scheme once it has a previous one, so that existing values and new ones stay comparable;
        # `fixed: false` makes it write with the newest, which is the whole point of a rotation (found by a spec that rotated and moved nothing).
        if deterministic && KmsEncryption.configuration.previous_wrapped_deterministic_keys.any?
          previous += KmsEncryption.configuration.previous_wrapped_deterministic_keys.map do |wrapped|
            { key_provider: KmsEncryption.deterministic_key_provider(info: "#{table_name}.#{name}", wrapped_key: wrapped), deterministic: true }
          end
          deterministic = { fixed: false }
        end
        encrypts name, key_provider: provider, deterministic: deterministic, previous: previous.presence, **options
      end
    end
  end
end
