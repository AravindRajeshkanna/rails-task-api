# Only while a column is being converted from plaintext (ENCRYPTION_ALLOW_PLAINTEXT=true; docs/runbooks/kms-key-rotation.md, "Encrypting an existing column").
#
# Rails' `extend_queries` makes `where(email_address: x)` also match a row that still holds x in plaintext, by adding the plaintext alternative to the
# query wrapped in an AdditionalValue. On an attribute that also has `normalizes` (users.email_address does), the normalization casts that wrapper to a
# string and the encrypted type then ENCRYPTS the string, so the alternative is a ciphertext of "#<AdditionalValue ...>" and matches nothing: anyone not yet
# converted could not sign in during the window. Found by rehearsing the conversion on a copy of the development database; stock Rails 8.1.4 does the same
# for a plain `encrypts :v, deterministic: true` with `normalizes :v`.
#
# The fix hands the wrapper to the encrypted type untouched, and normalizes the plaintext inside it, since the normal path (which normalizes before it
# encrypts) is not the one the alternative takes. A previous scheme's alternative is a ciphertext, which must not be touched; plaintext never starts with
# the `{"p":` of an encrypted message. It reaches into a :nodoc: class, so it exists only while the flag is on, and
# spec/initializers/encryption_transition_spec.rb fails if Rails changes the pieces it relies on: re-check it on every Rails upgrade and delete it when
# Rails no longer needs it.
if ENV["ENCRYPTION_ALLOW_PLAINTEXT"] == "true"
  ActiveSupport.on_load(:active_record) do
    ActiveModel::Attributes::Normalization::NormalizedValueType.prepend(Module.new do
      def serialize(value)
        return super unless value.is_a?(ActiveRecord::Encryption::ExtendedDeterministicQueries::AdditionalValue)

        alternative = __getobj__.serialize(value)
        alternative.is_a?(String) && !alternative.start_with?('{"p":') ? normalize(alternative) : alternative
      end
    end)
  end
end
