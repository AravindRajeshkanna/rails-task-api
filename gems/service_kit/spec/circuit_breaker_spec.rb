require "spec_helper"
require "service_kit/circuit_breaker"

RSpec.describe ServiceKit::CircuitBreaker do
  let(:down) { Class.new(StandardError) }
  let(:now) { [ 1_000.0 ] }
  let(:transitions) { [] }
  let(:breaker) do
    described_class.new(:dependency, failure_threshold: 3, window: 30, reset_timeout: 30, max_reset_timeout: 120, exceptions: [ down ], clock: -> { now.first })
  end

  before { described_class.observer = ->(name, from, to) { transitions << [ name, from, to ] } }
  after { described_class.observer = nil }

  def fail_once = breaker.call { raise down, "boom" }
  def succeed = breaker.call { :ok }

  it "passes calls through while it is closed, and returns their value" do
    expect(breaker.call { 42 }).to eq(42)
    expect(breaker.state).to eq(:closed)
  end

  it "opens after the threshold of consecutive failures, and then fails at once without calling the dependency" do
    3.times { expect { fail_once }.to raise_error(down) }
    calls = 0

    expect { breaker.call { calls += 1 } }.to raise_error(described_class::OpenError, /circuit dependency is open/)

    expect(calls).to eq(0)
    expect(breaker.state).to eq(:open)
    expect(transitions).to eq([ [ :dependency, :closed, :open ] ])
  end

  it "tells the caller how long to wait" do
    3.times { fail_once rescue nil }
    now[0] += 10

    error = begin; succeed; rescue described_class::OpenError => caught; caught; end

    expect(error.retry_after).to eq(20)
    expect(error.breaker).to eq(:dependency)
  end

  it "counts only consecutive failures: a success starts the count again" do
    2.times { fail_once rescue nil }
    succeed
    2.times { fail_once rescue nil }

    expect(breaker.state).to eq(:closed)
  end

  it "forgets failures that are too far apart to be one outage" do
    2.times { fail_once rescue nil }
    now[0] += 31
    fail_once rescue nil

    expect(breaker.state).to eq(:closed)
  end

  it "counts only the exceptions it was given: a mistake by the caller is not the dependency being down" do
    5.times { expect { breaker.call { raise ArgumentError, "bad input" } }.to raise_error(ArgumentError) }

    expect(breaker.state).to eq(:closed)
  end

  describe "after the reset timeout" do
    before do
      3.times { fail_once rescue nil }
      now[0] += 30
    end

    it "reports half-open, and lets exactly one probe through" do
      expect(breaker.state).to eq(:half_open)
      probes = 0
      concurrent = nil

      breaker.call do
        probes += 1
        concurrent = begin; breaker.call { probes += 1 }; rescue described_class::OpenError => error; error; end # another caller while the probe runs
      end

      expect(probes).to eq(1)
      expect(concurrent).to be_a(described_class::OpenError)
    end

    it "closes on a successful probe" do
      succeed

      expect(breaker.state).to eq(:closed)
      expect(transitions.last(2)).to eq([ [ :dependency, :open, :half_open ], [ :dependency, :half_open, :closed ] ])
      expect { succeed }.not_to raise_error
    end

    it "reopens on a failed probe, and waits twice as long next time, up to a ceiling" do
      fail_once rescue nil
      expect(breaker.state).to eq(:open)

      now[0] += 59
      expect(breaker.state).to eq(:open) # 60 s this time
      now[0] += 1
      fail_once rescue nil
      now[0] += 119
      expect(breaker.state).to eq(:open) # 120 s: doubled again
      now[0] += 1
      fail_once rescue nil
      now[0] += 119
      expect(breaker.state).to eq(:open) # and no longer than the ceiling
      now[0] += 1
      expect(breaker.state).to eq(:half_open)
    end

    it "goes back to the base timeout once it has recovered" do
      fail_once rescue nil
      now[0] += 60
      succeed
      3.times { fail_once rescue nil }
      now[0] += 29

      expect(breaker.state).to eq(:open)
      now[0] += 1
      expect(breaker.state).to eq(:half_open)
    end
  end

  it "is safe to call from many threads, and lets one probe through, not several" do
    3.times { fail_once rescue nil }
    now[0] += 30
    probes = Concurrent::AtomicFixnum.new
    refused = Concurrent::AtomicFixnum.new

    Array.new(20) do
      Thread.new do
        breaker.call { probes.increment; sleep 0.05 }
      rescue described_class::OpenError
        refused.increment
      end
    end.each(&:join)

    expect(probes.value).to eq(1)
    expect(refused.value).to eq(19)
  end

  it "keeps named breakers in a registry, one per name" do
    described_class.reset_all!
    first = described_class.for(:ai, failure_threshold: 2)

    expect(described_class.for(:ai)).to be(first)
    expect(described_class.for(:other)).not_to be(first)
  end
end
