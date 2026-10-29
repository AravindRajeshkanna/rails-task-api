require_relative "lib/ai_core/version"

Gem::Specification.new do |spec|
  spec.name = "ai_core"
  spec.version = AiCore::VERSION
  spec.authors = [ "Task API" ]
  spec.summary = "Provider-agnostic LLM inference for the Task API (Bedrock, plus an offline fake)."
  spec.description = <<~TEXT
    Pure inference: prompts, tool schemas, output validation, embeddings and an evaluation harness.
    No Rails and no database, so the same code runs in-process inside the monolith or behind the
    extracted AI service (services/ai).
  TEXT
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*", "evals/**/*"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "aws-sdk-bedrockruntime", "~> 1.0"
end
