require "spec_helper"
require "service_kit/backoff"

RSpec.describe ServiceKit::Backoff do
  it "doubles with each attempt, between half the interval and the whole of it" do
    { 1 => 1.0..2.0, 3 => 4.0..8.0, 6 => 32.0..64.0 }.each do |attempts, range|
      samples = Array.new(200) { described_class.delay(attempts: attempts) }

      expect(samples).to all(be_between(range.begin, range.end))
      expect(samples.uniq.size).to be > 100 # actually random
    end
  end

  it "never exceeds the cap, however many attempts" do
    samples = Array.new(200) { described_class.delay(attempts: 50, cap: 900) }

    expect(samples).to all(be_between(450.0, 900.0))
  end

  it "is deterministic with a seeded random, for tests" do
    a = described_class.delay(attempts: 4, random: Random.new(1))
    b = described_class.delay(attempts: 4, random: Random.new(1))

    expect(a).to eq(b)
  end
end
