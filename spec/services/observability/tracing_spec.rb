require "rails_helper"

RSpec.describe "Tracing" do
  let(:exporter) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }

  around do |example|
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
    Observability::Tracing.tracer_provider = provider
    example.run
  ensure
    Observability::Tracing.tracer_provider = nil
  end

  let(:user) { create(:user) }

  it "wraps each model call in a span carrying GenAI attributes and token usage" do
    Ai::Runner.new(user: user).run("parse_task", { text: "Call Sam tomorrow", today: "2026-10-29" })

    span = exporter.finished_spans.sole
    expect(span.name).to eq("ai.parse_task")
    expect(span.attributes).to include("gen_ai.operation.name" => "parse_task", "gen_ai.request.model" => "fake")
    expect(span.attributes["gen_ai.usage.input_tokens"]).to be_positive
  end

  it "records a failing call as an error span, without any user text" do
    with_ai_responder(->(_) { raise AiCore::Unavailable, "throttled" }) do
      expect { Ai::Runner.new(user: user).run("parse_task", { text: "secret plans", today: "2026-10-29" }) }.to raise_error(Ai::Unavailable)
    end

    span = exporter.finished_spans.sole
    expect(span.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
    expect(span.attributes.values.join).not_to include("secret plans")
  end

  it "annotates the request span with the user id only" do
    Observability::Tracing.in_span("request") do |span|
      Observability::Tracing.annotate_request(user_id: 42)
      expect(span.attributes).to eq("enduser.id" => "42")
    end
  end

  it "is harmless without an SDK" do
    Observability::Tracing.tracer_provider = nil # fall back to the global (no-op) provider

    expect(Observability::Tracing.current_ids).to be_nil
    expect(Observability::Tracing.in_span("x") { 1 }).to eq(1)
  end

  it "exposes the active trace ids for log correlation" do
    Observability::Tracing.in_span("work") do |span|
      expect(Observability::Tracing.current_ids).to eq(trace_id: span.context.hex_trace_id, span_id: span.context.hex_span_id)
    end
  end

  it "generates trace ids X-Ray accepts: the first four bytes are the epoch time" do
    id = OpenTelemetry::Propagator::XRay::IDGenerator.generate_trace_id

    expect(id.bytesize).to eq(16)
    expect(id[0, 4].unpack1("N")).to be_within(5).of(Time.now.to_i)
  end
end

RSpec.describe "Request context", type: :request do
  it "stamps events emitted during a request with its id and user, and clears it afterwards" do
    user = create(:user)
    project = create(:project, owner: user)

    events = record_events { api(:post, "/api/v1/projects/#{project.id}/tasks", { title: "Ship it" }, as: user) }

    created = events.events.find { |event| event[:name] == "task.created" }
    expect(created[:context]).to include(request_id: be_present, user_id: user.id)
    expect(Rails.event.context).to eq({})
  end
end
