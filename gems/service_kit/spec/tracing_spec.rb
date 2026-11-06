require "spec_helper"
require "json"
require "open3"
require "rbconfig"

# What the tracing initializer does to a real application, which a unit test of its pieces cannot show: the OpenTelemetry gems add their Rack middleware in a
# Railtie hook that runs early in boot, so they have to be loaded before the application boots, not from an initializer. Until this was found, every service
# installed the instrumentation, logged "successfully installed", and produced no span for a single request (no server span in Jaeger, no trace id on any log
# line, and the AI service, which has no database, seemed to send nothing at all). So each example boots a small Rails application, in a child process
# (tracing is process-wide and cannot be undone), sends it a request, and reads back what it made.
RSpec.describe "ServiceKit tracing" do
  lib = File.expand_path("../lib", __dir__)

  # A one-route API with the service_kit railtie, in development so that it is not the test environment the initializer skips, and an in-memory exporter on the
  # real provider. Prints one JSON line: the spans the request made and the log line the action wrote.
  script = <<~'RUBY'
    require "rails"
    require "action_controller/railtie"
    require "tmpdir"
    require "service_kit"
    require "net/http"
    require "socket"

    # A service for the action to call, which keeps the headers it was sent.
    CALLEE = TCPServer.new("127.0.0.1", 0)
    CALLED_WITH = Queue.new
    Thread.new do
      loop do
        client = CALLEE.accept
        head = +""
        while (line = client.gets) && line != "\r\n"
          head << line
        end
        CALLED_WITH << head
        client.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
        client.close
      end
    end

    class HelloController < ActionController::API
      def show
        Rails.logger.info("hello from the action")
        Net::HTTP.get(URI("http://127.0.0.1:#{CALLEE.addr[1]}/")) if ENV["CALL_OUT"]
        render json: { hello: params[:name] }
      end
    end

    LOG = StringIO.new

    class TracedApp < Rails::Application
      config.root = Dir.mktmpdir
      config.eager_load = false
      config.api_only = true
      config.secret_key_base = "not-a-secret"
      config.hosts.clear
      config.logger = Logger.new(LOG)
      config.log_level = :info
      config.service_kit.name = "traced-app"
    end
    TracedApp.routes.append { get "/hello/:name", to: "hello#show" }
    TracedApp.initialize!

    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    provider = OpenTelemetry.tracer_provider
    provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)) if provider.respond_to?(:add_span_processor) # not configured: nothing to read

    headers = {}
    headers["HTTP_TRACEPARENT"] = ENV["TRACEPARENT"] if ENV["TRACEPARENT"]
    headers["HTTP_X_AMZN_TRACE_ID"] = ENV["AMZN_TRACE_ID"] if ENV["AMZN_TRACE_ID"]
    paths = ENV.fetch("PATHS", "/hello/ada").split(",")
    statuses = paths.map do |path|
      status, _headers, body = TracedApp.call(Rack::MockRequest.env_for(path, headers))
      body.close # a server does; the span of a request ends when its body is closed
      status
    end

    puts JSON.generate(
      middleware: TracedApp.middleware.map { |middleware| middleware.name.to_s },
      statuses: statuses,
      callee_traceparent: (CALLED_WITH.pop[/^traceparent: (.*)$/i, 1].to_s.strip unless CALLED_WITH.empty?),
      service: (provider.resource.attribute_enumerator.to_h["service.name"] if provider.respond_to?(:resource)),
      spans: exporter.finished_spans.map { |span| { name: span.name, kind: span.kind, trace_id: span.hex_trace_id, parent: span.hex_parent_span_id, attributes: span.attributes.to_h } },
      log: LOG.string.lines.map { |line| JSON.parse(line) rescue line }
    )
    $stdout.flush
    exit!(0) # skip the shutdown flush: the exporter's endpoint is a closed port
  RUBY

  run_app = lambda do |env = {}|
    environment = { "RAILS_ENV" => "development", "OTEL_EXPORTER_OTLP_ENDPOINT" => "http://127.0.0.1:9", "OTEL_TRACES_SAMPLER" => "always_on",
                    "OTEL_BSP_SCHEDULE_DELAY" => "60000", "LOG_FORMAT" => "json" }.merge(env)
    out, err, status = Open3.capture3(environment, RbConfig.ruby, "-I", lib, "-e", script)
    raise "the child application failed (#{status.exitstatus}):\n#{err.lines.last(15).join}" unless status.success?

    JSON.parse(out.lines.reverse.find { |line| line.start_with?("{") })
  end

  it "makes one server span for a request, named for the route and not for the address" do
    result = run_app.call

    servers = result["spans"].select { |span| span["kind"] == "server" }
    expect(result["statuses"]).to eq([ 200 ])
    expect(servers.map { |span| span["name"] }).to eq([ "GET /hello/:name" ])
    expect(servers.first["attributes"]).to include("http.route" => "/hello/:name", "code.namespace" => "HelloController", "code.function" => "show")
  end

  it "puts one tracer at the front of the middleware stack" do
    result = run_app.call

    expect(result["middleware"].first).to eq("Rack::Events")
    expect(result["middleware"].count("Rack::Events")).to eq(1)
  end

  it "puts the trace and span ids of the request on the log lines it writes" do
    result = run_app.call

    server = result["spans"].find { |span| span["kind"] == "server" }
    line = result["log"].find { |entry| entry.is_a?(Hash) && entry["message"] == "hello from the action" }
    expect(line).to include("trace_id" => server["trace_id"])
    expect(line["span_id"]).to match(/\A\h{16}\z/)
  end

  it "continues the trace the caller sent, so that one request is one trace across services" do
    trace_id = "0af7651916cd43dd8448eb211c80319c"
    result = run_app.call("TRACEPARENT" => "00-#{trace_id}-b7ad6b7169203331-01")

    server = result["spans"].find { |span| span["kind"] == "server" }
    expect(server).to include("trace_id" => trace_id, "parent" => "b7ad6b7169203331")
  end

  it "continues a trace begun at the load balancer, which sends X-Amzn-Trace-Id and not traceparent" do
    result = run_app.call("AMZN_TRACE_ID" => "Root=1-5759e988-bd862e3fe1be46a994272793;Parent=53995c3f42cd8ad8;Sampled=1")

    server = result["spans"].find { |span| span["kind"] == "server" }
    expect(server).to include("trace_id" => "5759e988bd862e3fe1be46a994272793", "parent" => "53995c3f42cd8ad8")
  end

  it "records what the caller sampled and drops what it did not, whatever its own ratio" do
    unset = { "OTEL_TRACES_SAMPLER" => nil } # the default: a tenth of new traces, and the caller's decision for the rest
    sampled = run_app.call(unset.merge("TRACEPARENT" => "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"))
    dropped = run_app.call(unset.merge("TRACEPARENT" => "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00"))

    expect(sampled["spans"].count { |span| span["kind"] == "server" }).to eq(1)
    expect(dropped["spans"]).to be_empty
  end

  it "names the service from OTEL_SERVICE_NAME, and otherwise as the caller of configure asked" do
    expect(run_app.call["service"]).to eq("task-api-service")
    expect(run_app.call("OTEL_SERVICE_NAME" => "ai-service")["service"]).to eq("ai-service")
  end

  it "passes the trace on to a service it calls, which is what makes one request one trace across services" do
    result = run_app.call("CALL_OUT" => "1")

    server = result["spans"].find { |span| span["kind"] == "server" }
    client = result["spans"].find { |span| span["kind"] == "client" }
    expect(client).to include("trace_id" => server["trace_id"])
    expect(result["callee_traceparent"]).to match(/\A00-#{server['trace_id']}-\h{16}-01\z/)
  end

  it "starts traces with ids X-Ray accepts: the first eight digits are the time, in seconds" do
    result = run_app.call

    server = result["spans"].find { |span| span["kind"] == "server" }
    expect(server["trace_id"][0, 8].to_i(16)).to be_within(120).of(Time.now.to_i)
  end

  it "does not trace the health check or the metrics endpoint, which a probe calls every few seconds" do
    result = run_app.call("PATHS" => "/up,/metrics")

    expect(result["spans"].select { |span| span["kind"] == "server" }).to be_empty
  end

  it "does nothing without an exporter endpoint, unset or empty (docker compose passes it empty): no middleware, no SDK" do
    [ nil, "" ].each do |endpoint| # unset, the SDK would trace to its default (localhost:4318); empty, it fails to build its exporter and stays off
      result = run_app.call("OTEL_EXPORTER_OTLP_ENDPOINT" => endpoint)

      expect(result["spans"]).to be_empty, "endpoint #{endpoint.inspect}"
      expect(result["middleware"]).not_to include("Rack::Events"), "endpoint #{endpoint.inspect}"
    end
  end

  it "is off in the test environment, whatever the endpoint" do
    result = run_app.call("RAILS_ENV" => "test")

    expect(result["spans"]).to be_empty
  end

  it "is off when OTEL_SDK_DISABLED says so" do
    result = run_app.call("OTEL_SDK_DISABLED" => "true")

    expect(result["spans"]).to be_empty
  end
end
