require "rails_helper"
require "open3"
require "rbconfig"

# The application as a server runs it, not as the suite does (tracing is off in the test environment, and process-wide): booted in a child process in
# development with an exporter endpoint set, and sent a request. Until the setup moved to ServiceKit::Tracing the app reported its instrumentation as installed
# and traced no request at all (gems/service_kit/spec/tracing_spec.rb has the full story and the cases around it).
RSpec.describe "config/initializers/opentelemetry.rb" do
  script = <<~RUBY
    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    OpenTelemetry.tracer_provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
    status, _headers, body = Rails.application.call(Rack::MockRequest.env_for("/livez", "HTTP_HOST" => "localhost"))
    body.close
    puts JSON.generate(
      status: status, service: OpenTelemetry.tracer_provider.resource.attribute_enumerator.to_h["service.name"],
      middleware: Rails.application.middleware.map { |middleware| middleware.name.to_s },
      spans: exporter.finished_spans.map { |span| { name: span.name, kind: span.kind } }
    )
    $stdout.flush
    exit!(0) # skip the shutdown flush: the exporter's endpoint is a closed port
  RUBY

  def boot(env = {}, script:)
    environment = { "RAILS_ENV" => "development", "OTEL_EXPORTER_OTLP_ENDPOINT" => "http://127.0.0.1:9", "OTEL_TRACES_SAMPLER" => "always_on",
                    "OTEL_BSP_SCHEDULE_DELAY" => "60000" }.merge(env)
    out, err, status = Open3.capture3(environment, RbConfig.ruby, Rails.root.join("bin/rails").to_s, "runner", script, chdir: Rails.root.to_s)
    raise "the application did not boot (#{status.exitstatus}):\n#{err.lines.last(15).join}" unless status.success?

    JSON.parse(out.lines.reverse.find { |line| line.start_with?("{") })
  end

  it "traces a request to the application: one server span, named for the route" do
    result = boot(script: script)

    expect(result["status"]).to eq(200)
    expect(result["spans"].select { |span| span["kind"] == "server" }.map { |span| span["name"] }).to eq([ "GET /livez" ])
    expect(result["middleware"].first).to eq("Rack::Events")
  end

  it "is named task-api, unless OTEL_SERVICE_NAME says otherwise" do
    expect(boot(script: script)["service"]).to eq("task-api")
    expect(boot({ "OTEL_SERVICE_NAME" => "task-api-worker" }, script: script)["service"]).to eq("task-api-worker")
  end

  it "is the same setup the services use" do
    expect(Rails.root.join("config/initializers/opentelemetry.rb").read).to include("ServiceKit::Tracing.configure")
  end
end
