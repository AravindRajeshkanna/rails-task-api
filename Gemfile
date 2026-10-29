source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.4"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
# gem "jbuilder"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
gem "image_processing", "~> 2.2"

# Use Rack CORS for handling Cross-Origin Resource Sharing (CORS), making cross-origin Ajax possible
gem "rack-cors"

# Throttling and blocking abusive clients at the Rack layer [https://github.com/rack/rack-attack]
gem "rack-attack"

# Fast, explicit JSON serializers [https://github.com/okuramasafumi/alba]
gem "alba"

# Lightweight pagination [https://github.com/ddnexus/pagy]
gem "pagy"

# Policy-based authorization [https://github.com/varvet/pundit]
gem "pundit"

# OpenAPI (Swagger) documentation served from the app; specs live in the test group
gem "rswag-api"
gem "rswag-ui"

# Error tracking; stays inert unless SENTRY_DSN is set
gem "sentry-ruby"
gem "sentry-rails"

# AI: provider-agnostic inference (Bedrock, plus an offline fake). Lives in gems/ai_core so it can also
# run behind the extracted AI service (services/ai).
gem "ai_core", path: "gems/ai_core"

# AWS: SNS publishes domain events for the other services; S3 stores Active Storage files on Kubernetes
gem "aws-sdk-sns"
gem "aws-sdk-s3", require: false

# Verifies JWTs issued by the Auth service. require: false keeps the kit's Railtie (logging, metrics,
# tracing for the extracted services) out of the monolith, which has its own; see config/initializers.
gem "service_kit", path: "gems/service_kit", require: false

# pgvector support for Active Record (embeddings and nearest-neighbor search)
gem "neighbor"

# Observability: Prometheus metrics, and OpenTelemetry traces exported over OTLP (to AWS X-Ray via the ADOT collector)
gem "prometheus-client"
gem "opentelemetry-sdk"
gem "opentelemetry-exporter-otlp"
gem "opentelemetry-propagator-xray"
gem "opentelemetry-instrumentation-rails"
gem "opentelemetry-instrumentation-pg"
gem "opentelemetry-instrumentation-net_http"
gem "opentelemetry-instrumentation-aws_sdk"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false

  # Testing: RSpec + FactoryBot + Faker + Shoulda Matchers
  gem "rspec-rails"
  gem "factory_bot_rails"
  gem "faker"
  gem "shoulda-matchers"
  gem "pundit-matchers"
  gem "webmock"

  # Generate OpenAPI documents from request specs
  gem "rswag-specs"

  # The AIOps Lambdas (deploy/lambda/aiops) run on the Lambda runtime, which bundles the AWS SDK; these are for their specs
  gem "aws-sdk-cloudwatch"
  gem "aws-sdk-cloudwatchlogs"
  gem "aws-sdk-eks"
  gem "aws-sdk-xray"

  # Detect N+1 queries and unused eager loading (raises in test)
  gem "bullet"
end
