#!/usr/bin/env ruby
# Makes Rails credentials that belong to nobody, for a checkout that has no config/master.key: a pull request's CI run (a fork's gets no secrets),
# or a clone by someone who is not the owner. The real credentials file cannot be read without the owner's key; the platform only needs *a* key and a
# file it opens (secret_key_base and the Active Record encryption keys), so the stack can start and deploy/local/verify.sh can run.
#
#   key=$(bundle exec ruby deploy/local/throwaway_credentials.rb)     # prints the key, writes config/credentials/production.yml.enc
#   RAILS_MASTER_KEY=$key docker compose up -d --build
#
# Rails reads config/credentials/production.yml.enc in place of config/credentials.yml.enc when RAILS_ENV=production, and the committed file is left
# alone. Nothing it makes is worth stealing, and none of it may reach a real deploy: it refuses to run where config/master.key exists (the owner's
# machine) or where it has already run, and `rm config/credentials/production.yml.enc` undoes it.
require "active_support"
require "active_support/encrypted_configuration"
require "fileutils"
require "securerandom"

root = File.expand_path(ARGV.fetch(0, File.join(__dir__, "../..")))
credentials = File.join(root, "config/credentials/production.yml.enc")

abort "config/master.key exists: these are the real credentials' keys, and a throwaway file beside them could end up in a real deploy" if File.exist?(File.join(root, "config/master.key"))
abort "#{credentials} exists already: remove it to make another" if File.exist?(credentials)

key = ActiveSupport::EncryptedFile.generate_key
ENV["RAILS_MASTER_KEY"] = key # the file's key is read from here
FileUtils.mkdir_p(File.dirname(credentials))
ActiveSupport::EncryptedConfiguration.new(
  config_path: credentials, key_path: File.join(root, "config/credentials/production.key"), env_key: "RAILS_MASTER_KEY", raise_if_missing_key: true
).write(
  {
    "secret_key_base" => SecureRandom.hex(64),
    "active_record_encryption" => {
      "primary_key" => SecureRandom.alphanumeric(32), "deterministic_key" => SecureRandom.alphanumeric(32), "key_derivation_salt" => SecureRandom.alphanumeric(32)
    }
  }.to_yaml
)
puts key
