require "spec_helper"
require "kms_encryption"

RSpec.describe KmsEncryption::KeyCache do
  let(:now) { [ 100.0 ] }
  let(:cache) { described_class.new(ttl: 300, size: 3, clock: -> { now.first }) }

  it "computes a value once and serves it from memory afterwards" do
    calls = 0
    2.times { expect(cache.fetch("a") { calls += 1; "key" }).to eq("key") }
    expect(calls).to eq(1)
  end

  it "asks again once the ttl has passed, and not before" do
    calls = 0
    cache.fetch("a") { calls += 1 }
    now[0] += 299
    cache.fetch("a") { calls += 1 }
    expect(calls).to eq(1)
    now[0] += 2
    cache.fetch("a") { calls += 1 }
    expect(calls).to eq(2)
  end

  it "never remembers a failure" do
    calls = 0
    2.times { expect { cache.fetch("a") { calls += 1; raise "kms is down" } }.to raise_error("kms is down") }
    expect(calls).to eq(2)
    expect(cache.size).to eq(0)
  end

  it "evicts the least recently used entry when full" do
    %w[a b c].each { |name| cache.fetch(name) { name } }
    cache.fetch("a") { raise "a should still be cached" } # a is now the most recent
    cache.fetch("d") { "d" }                              # evicts b, the least recently used

    expect(cache.size).to eq(3)
    expect(cache.fetch("a") { raise "a was evicted" }).to eq("a")
    expect(cache.fetch("b") { "recomputed" }).to eq("recomputed")
  end

  it "can be given a value to remember without computing it, and still ages it out" do
    cache.store("a", "key")
    expect(cache.fetch("a") { raise "should not be asked" }).to eq("key")

    now[0] += 301
    expect(cache.fetch("a") { "recomputed" }).to eq("recomputed")
  end

  it "can be emptied" do
    cache.fetch("a") { 1 }
    cache.clear
    expect(cache.size).to eq(0)
  end
end
