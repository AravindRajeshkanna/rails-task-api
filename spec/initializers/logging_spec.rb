require "rails_helper"

RSpec.describe JsonLogFormatter do
  subject(:formatter) { described_class.new }

  def line(message, **) = JSON.parse(formatter.call("INFO", Time.utc(2026, 10, 29, 12, 0, 0, 123_000), nil, message))

  it "logs plain messages under message" do
    expect(line("hello")).to eq("time" => "2026-10-29T12:00:00.123Z", "level" => "INFO", "message" => "hello")
  end

  it "lifts hash messages to top-level fields, which is how events and EMF lines are logged" do
    entry = line({ event: "task.completed", project_id: 3 })

    expect(entry).to include("event" => "task.completed", "project_id" => 3, "level" => "INFO")
    expect(entry).not_to have_key("message")
  end

  it "does not let an event overwrite the envelope" do
    entry = line({ event: "x", level: "FATAL", time: "yesterday", request_id: "forged" })

    expect(entry).to include("level" => "INFO", "time" => "2026-10-29T12:00:00.123Z")
    expect(entry).not_to have_key("request_id")
  end

  it "carries the trace and span ids of the active span, so logs link to traces" do
    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
    Observability::Tracing.tracer_provider = provider

    Observability::Tracing.in_span("work") do |span|
      expect(line("inside")).to include("trace_id" => span.context.hex_trace_id, "span_id" => span.context.hex_span_id)
    end
    expect(line("outside")).not_to have_key("trace_id")
  ensure
    Observability::Tracing.tracer_provider = nil
  end

  it "drops Rails' text request log, which the structured access log replaces" do
    [ 'Started GET "/up" for ::1 at 2026-10-29', "Processing by Api::V1::MeController#show as JSON", "Completed 200 OK in 3ms (Views: 0.1ms)", "  Parameters: {\"a\"=>1}" ].each do |text|
      expect(formatter.call("INFO", Time.now, nil, text)).to eq("")
    end
    expect(formatter.call("INFO", Time.now, nil, "Completed the migration")).to include("Completed the migration")
  end

  it "is how production logs when LOG_FORMAT is json (the default there)" do
    expect(Rails.configuration.x.json_logs).to be(false) # test environment: plain
  end
end

RSpec.describe Events::LogSubscriber do
  let(:event) { { name: "task.created", payload: { subject: "gid://x/Task/1", project_id: 2 }, context: { request_id: "abc", user_id: 9 }, tags: {}, timestamp: 0 } }

  it "writes key=value lines in plain mode, including the request context" do
    expect(Rails.logger).to receive(:info).with("event=task.created subject=gid://x/Task/1 project_id=2 request_id=abc user_id=9")

    described_class.new.emit(event)
  end

  it "writes a structured entry in JSON mode" do
    allow(Rails.configuration.x).to receive(:json_logs).and_return(true)
    expect(Rails.logger).to receive(:info).with({ event: "task.created", subject: "gid://x/Task/1", project_id: 2, request_id: "abc", user_id: 9 })

    described_class.new.emit(event)
  end
end

RSpec.describe Events::LogSubscriber::LOGGED do
  it "logs our events and the access log, but not framework chatter" do
    %w[task.created ai.completed membership.updated action_controller.request_completed active_job.completed].each { |name| expect(name).to match(described_class) }
    %w[active_record.sql action_view.render_template action_controller.request_started active_job.started].each { |name| expect(name).not_to match(described_class) }
  end
end
