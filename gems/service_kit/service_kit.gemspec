require_relative "lib/service_kit/version"

Gem::Specification.new do |spec|
  spec.name = "service_kit"
  spec.version = ServiceKit::VERSION
  spec.authors = [ "Task API" ]
  spec.summary = "What every Task API service shares: JWT verification, JSON logs, Prometheus metrics, OpenTelemetry."
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "jwt", ">= 2.9"
  spec.add_dependency "prometheus-client"
  spec.add_dependency "opentelemetry-sdk"
  spec.add_dependency "opentelemetry-exporter-otlp"
  spec.add_dependency "opentelemetry-propagator-xray"
  spec.add_dependency "opentelemetry-instrumentation-rails"
  spec.add_dependency "opentelemetry-instrumentation-pg"
  spec.add_dependency "opentelemetry-instrumentation-net_http"
  spec.add_dependency "opentelemetry-instrumentation-aws_sdk"
end
