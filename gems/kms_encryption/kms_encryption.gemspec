require_relative "lib/kms_encryption/version"

Gem::Specification.new do |spec|
  spec.name = "kms_encryption"
  spec.version = KmsEncryption::VERSION
  spec.authors = [ "Task API" ]
  spec.summary = "Key providers for Active Record Encryption whose keys are protected by AWS KMS: envelope encryption with an encryption context, a bounded key cache, and a local stand-in for development and tests."
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "activerecord", ">= 8.0"
  spec.add_dependency "aws-sdk-kms", "~> 1.0"
end
