# Distributed tracing with OpenTelemetry, exported over OTLP. In EKS the endpoint is the ADOT collector
# (a DaemonSet or sidecar) whose awsxray exporter delivers traces to AWS X-Ray; locally it can be any
# OTLP backend (docker compose ships a collector and Jaeger).
#
# Off unless OTEL_EXPORTER_OTLP_ENDPOINT is set, so development, tests and CI are unaffected. Standard
# OTEL_* variables apply: OTEL_SERVICE_NAME, OTEL_TRACES_SAMPLER(_ARG), OTEL_RESOURCE_ATTRIBUTES, ...
# The setup is the services' too (gems/service_kit/lib/service_kit/tracing.rb), so that the four cannot differ.
require "service_kit/tracing"

ServiceKit::Tracing.configure(default_service_name: "task-api") if ServiceKit::Tracing.enabled?
