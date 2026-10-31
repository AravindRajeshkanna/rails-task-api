# Where the keys of encrypted attributes come from (ADR 69, docs/aws/kms.md). One of:
#
#   KMS_KEY_ID=alias/task-api-prod-data     AWS KMS protects the keys. Needs KMS_WRAPPED_DETERMINISTIC_KEY as well (a wrapped secret that Terraform
#                                           makes; see deploy/terraform/kms.tf) and kms:GenerateDataKey and kms:Decrypt on the key.
#   ENCRYPTION_KEY_SOURCE=credentials       Rails' own keys from config/credentials.yml.enc, as before. For what is not on AWS: Kamal, docker compose.
#   (neither)                               development and test: an in-memory stand-in for KMS with a public key. Refused in production, where it
#                                           would encrypt with a key anyone can read in this repository.
#
# Nothing here calls KMS. The first use does (readiness waits for it), so booting for a build or a migration needs no AWS access.
KmsEncryption.configure do |config|
  config.key_id = ENV["KMS_KEY_ID"].presence
  config.wrapped_deterministic_key = ENV["KMS_WRAPPED_DETERMINISTIC_KEY"].presence
  config.endpoint = ENV["KMS_ENDPOINT"].presence
  # Set only while the addresses are being moved to a new master (the runbook says when); comma-separated, newest first.
  config.previous_wrapped_deterministic_keys = ENV.fetch("KMS_PREVIOUS_WRAPPED_DETERMINISTIC_KEYS", "").split(",").map(&:strip).compact_blank

  requested = ENV["ENCRYPTION_KEY_SOURCE"].presence
  config.source =
    if Rails.env.test? then :local # never AWS from a spec, whatever the shell has exported
    elsif requested then requested
    elsif config.key_id then :kms
    elsif Rails.env.production? then nil # no source: the first use raises NotConfigured and /readyz fails, instead of guessing
    else :local
    end

  raise "ENCRYPTION_KEY_SOURCE=local encrypts with a public key; it is for development and tests only" if config.local? && Rails.env.production?

  # The stand-in needs a name for its key just as KMS does.
  config.key_id ||= "alias/task-api-#{Rails.env}-data" if config.local?
end
