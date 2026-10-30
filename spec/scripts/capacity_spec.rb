require "rails_helper"
require Rails.root.join("loadtest/capacity").to_s

RSpec.describe Capacity do
  it "sizes the fleet from the measured ceiling of one pod, leaving headroom" do
    plan = described_class.plan(peak_rps: 910) # 260 * 0.7 = 182 usable per pod

    expect(plan.pods).to eq(5)
  end

  it "keeps enough pods to carry the peak after losing a zone" do
    plan = described_class.plan(peak_rps: 900, spread: 3)
    surviving = plan.pods_after_losing_a_zone * 2 / 3.0 # a third of the fleet is gone

    expect(plan.pods_after_losing_a_zone).to be >= plan.pods
    expect(900 / surviving).to be <= 260 * 0.9 # the survivors run hot but under the ceiling
  end

  it "never plans fewer pods for more load" do
    pods = [ 50, 100, 400, 900, 2_000, 8_000 ].map { |peak| described_class.plan(peak_rps: peak).pods_after_losing_a_zone }

    expect(pods).to eq(pods.sort)
    expect(pods.uniq.size).to be > 3
  end

  it "counts a database connection for every thread of every API pod and worker, plus what is reserved" do
    plan = described_class.plan(peak_rps: 900, threads: 5, workers: 2, worker_threads: 7, reserved: 20)

    expect(plan.database_connections).to eq(plan.pods_after_losing_a_zone * 5 + 2 * 7 + 20)
  end

  it "uses Aurora's published limit, capped at 5,000, which grows with the ACU ceiling" do
    expect(described_class.max_connections(8)).to eq(1_802)
    expect(described_class.max_connections(16)).to eq(3_604)
    expect(described_class.max_connections(64)).to eq(5_000)
  end

  it "says so when the fleet needs more connections than the database allows, and what to do" do
    plan = described_class.plan(peak_rps: 30_000, acu: 4)

    expect(plan.connection_headroom).to be_negative
    expect(described_class.report(plan, peak_rps: 30_000)).to include("cannot take this many connections", "RDS Proxy")
  end

  it "refuses to guess a load" do
    expect { described_class.plan }.to raise_error(ArgumentError, /peak_rps/)
  end

  it "runs from the command line" do
    output = IO.popen([ RbConfig.ruby, Rails.root.join("loadtest/capacity.rb").to_s, "--peak-rps", "900" ], &:read)

    expect(output).to include("peak load", "pods", "database connections")
  end
end
