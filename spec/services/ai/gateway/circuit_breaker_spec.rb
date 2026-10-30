require "rails_helper"

# What the breakers around the model provider and the AI service do to a caller (ADR 58).
RSpec.describe "AI gateways behind a circuit breaker", type: :request do
  let(:now) { [ 1_000.0 ] }
  let(:clock) { -> { now.first } }

  def breaker_with_fake_clock(name, exceptions)
    ServiceKit::CircuitBreaker.registry[name] = ServiceKit::CircuitBreaker.new(name, failure_threshold: 5, window: 30, reset_timeout: 30, exceptions: exceptions, clock: clock)
  end

  describe Ai::Gateway::Remote do
    let(:gateway) { described_class.new(url: "http://ai.test", token: "t") }
    let!(:breaker) { breaker_with_fake_clock(:ai_service, [ Ai::Unavailable ]) }

    it "stops calling a service that keeps failing, and says when to come back" do
      stub = stub_request(:post, "http://ai.test/v1/embeddings").to_timeout

      5.times { expect { gateway.embed("x") }.to raise_error(Ai::Unavailable, /unreachable/) }
      expect(stub).to have_been_requested.times(5)

      error = (begin; gateway.embed("x"); rescue Ai::Unavailable => caught; caught; end)
      expect(error.message).to match(/not calling it for 30s/)
      expect(error.retry_after).to eq(30)
      expect(stub).to have_been_requested.times(5) # the sixth call never left the process
    end

    it "lets one probe through after the pause, and closes again when it works" do
      stub_request(:post, "http://ai.test/v1/embeddings").to_timeout
      5.times { gateway.embed("x") rescue nil }
      now[0] += 30
      stub_request(:post, "http://ai.test/v1/embeddings").to_return(status: 200, body: { vector: [ 0.5 ], usage: {} }.to_json)

      expect(gateway.embed("x").vector).to eq([ 0.5 ])
      expect(breaker.state).to eq(:closed)
    end

    it "does not count the caller's mistakes or a model that answered nonsense as the service being down" do
      stub_request(:post, "http://ai.test/v1/embeddings").to_return(status: 502, body: { error: { code: "ai_invalid_response" } }.to_json)

      10.times { expect { gateway.embed("x") }.to raise_error(Ai::InvalidResponse) }

      expect(breaker.state).to eq(:closed)
    end

    it "counts a 5xx and the service's own unavailable or rate_limited as down" do
      stub_request(:post, "http://ai.test/v1/embeddings").to_return(status: 503, body: { error: { code: "ai_unavailable" } }.to_json)

      5.times { gateway.embed("x") rescue nil }

      expect(breaker.state).to eq(:open)
    end
  end

  describe Ai::Gateway::Local do
    let(:gateway) { described_class.new }
    let!(:breaker) { breaker_with_fake_clock(:ai_provider, [ AiCore::Unavailable ]) }
    let(:client) { instance_double(AiCore::Client) }

    before { allow(AiCore).to receive(:client).and_return(client) }

    it "stops calling a provider that keeps timing out" do
      allow(client).to receive(:embed).and_raise(AiCore::Unavailable, "Bedrock timed out")

      5.times { expect { gateway.embed("x") }.to raise_error(Ai::Unavailable, "Bedrock timed out") }
      expect { gateway.embed("x") }.to raise_error(Ai::Unavailable, /not calling it/)

      expect(client).to have_received(:embed).exactly(5).times
    end

    it "does not open for a configuration error, which is ours to fix" do
      allow(client).to receive(:embed).and_raise(AiCore::ConfigurationError, "no model")

      10.times { expect { gateway.embed("x") }.to raise_error(Ai::Disabled) }

      expect(breaker.state).to eq(:closed)
    end
  end

  describe "as a user sees it" do
    let(:user) { create(:user) }
    let!(:project) { create(:project, owner: user) }

    it "is a 503 ai_unavailable with the breaker's Retry-After, the same envelope as a single failure" do
      breaker_with_fake_clock(:ai_provider, [ AiCore::Unavailable ])
      client = instance_double(AiCore::Client)
      allow(AiCore).to receive(:client).and_return(client)
      allow(AiCore).to receive(:enabled?).and_return(true)
      %i[run embed converse].each { |call| allow(client).to receive(call).and_raise(AiCore::Unavailable, "down") }

      api :post, "/api/v1/ai/suggest_priority", { project_id: project.id, title: "x" }, as: user
      expect(response.headers["Retry-After"]).to eq("5") # one failure: try again in a few seconds
      5.times { api :post, "/api/v1/ai/suggest_priority", { project_id: project.id, title: "x" }, as: user }

      api :post, "/api/v1/ai/suggest_priority", { project_id: project.id, title: "x" }, as: user

      expect(response).to have_http_status(:service_unavailable)
      expect(error["code"]).to eq("ai_unavailable")
      expect(response.headers["Retry-After"]).to eq("30")
    end
  end

  it "reports each breaker's state as a metric, and counts its transitions" do
    breaker = breaker_with_fake_clock(:ai_service, [ Ai::Unavailable ])
    3.times { breaker.call { raise Ai::Unavailable } rescue nil }
    2.times { breaker.call { raise Ai::Unavailable } rescue nil }

    Observability::Collector.reset!
    Observability::Collector.refresh!

    expect(Observability::Metrics::CIRCUIT_STATE.get(labels: { breaker: "ai_service" })).to eq(2)
    expect(Observability::Metrics::CIRCUIT_TRANSITIONS.get(labels: { breaker: "ai_service", to: "open" })).to be >= 1
  end
end
