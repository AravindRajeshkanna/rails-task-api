require "rails_helper"
require Rails.root.join("deploy/scripts/drill_probe").to_s

RSpec.describe DrillProbe, type: :request do
  # Talks to this application in-process, as a client would over the network.
  let(:client_class) do
    Class.new do
      def initialize(token)
        @token = token
        @rack = Rack::MockRequest.new(Rails.application)
      end

      def get(path) = call(:get, path)
      def post(path, body) = call(:post, path, JSON.generate(body))

      private
        def call(verb, path, body = nil)
          response = @rack.request(verb.to_s.upcase, path, input: body, "CONTENT_TYPE" => "application/json",
                                                           "HTTP_AUTHORIZATION" => "Bearer #{@token}", "HTTP_HOST" => "www.example.com")
          [ response.status, response.body ]
        end
    end
  end

  let(:user) { create(:user) }
  let(:project) { create(:project, owner: user) }
  let(:token) { auth_headers(user)["Authorization"].split.last }
  let(:now) { [ 1_800_000_000.0 ] }
  let(:probe) do
    described_class::Probe.new(client: client_class.new(token), project_id: project.id, run_id: "t1",
                               clock: -> { now.first }, sleeper: ->(seconds) { now[0] += seconds })
  end

  def read_only(on)
    original = Rails.configuration.x.read_only
    Rails.configuration.x.read_only = on
    yield
  ensure
    Rails.configuration.x.read_only = original
  end

  def report(missing: probe.missing(attempts: 1)) = described_class::Report.new(probe.samples, acknowledged: probe.acknowledged, missing: missing, run_id: "t1")

  it "sees a healthy service as no outage and no lost writes" do
    probe.run(duration: 5)

    expect(probe.samples.map { |sample| [ sample.read, sample.write ] }).to all(eq([ 200, 201 ]))
    expect(report.outages(:read) + report.outages(:write)).to be_empty
    expect(report.time_to_full_service).to eq(0.0)
    expect(probe.missing).to eq([])
    expect(report.to_s).to include("acknowledged writes lost: 0 of 5")
  end

  it "measures a window where writes are refused but reads work, as read-only mode produces" do
    2.times { probe.tick; now[0] += 1 }
    read_only(true) { 4.times { probe.tick; now[0] += 1 } }
    2.times { probe.tick; now[0] += 1 }

    expect(report.outages(:read)).to be_empty
    write_outage = report.outages(:write).sole
    expect(write_outage).to include(ticks: 4, statuses: { 503 => 4 })
    expect(write_outage[:to] - write_outage[:from]).to eq(4.0)
    expect(report.time_to_full_service).to eq(4.0)
    expect(probe.acknowledged.size).to eq(4)
    expect(probe.missing).to eq([])
    expect(report.to_s).to include("writes: 4 ok, 4 failed").and include("answers {503 => 4}").and include("time to full service: 4.0 s")
  end

  it "reports acknowledged writes that did not survive, which is the RPO in rows" do
    5.times { probe.tick; now[0] += 1 }
    lost = probe.acknowledged.last(2)
    Task.where(project: project, title: lost).delete_all # what an unplanned failover with data loss looks like

    expect(probe.missing).to eq(lost)
    expect(report.to_s).to include("acknowledged writes lost: 2 of 5").and include(lost.first)
  end

  it "counts connection errors as outages and says when the end state could not be read" do
    broken = Class.new { def get(_path) = [ :error, "" ] and def post(*) = [ :error, "" ] }.new
    failing = described_class::Probe.new(client: broken, project_id: 1, run_id: "t2", clock: -> { now.first }, sleeper: ->(seconds) { now[0] += seconds })
    3.times { failing.tick; now[0] += 1 }
    result = described_class::Report.new(failing.samples, acknowledged: failing.acknowledged, missing: failing.missing(attempts: 1), run_id: "t2")

    expect(result.outages(:read).sole).to include(ticks: 3, to: nil)
    expect(result.time_to_full_service).to be_nil
    expect(result.to_s).to include("NOT RECOVERED").and include("UNKNOWN")
  end

  it "keeps a run's tasks apart from every other task in the project" do
    create(:task, project: project, title: "drill-t1-not-ours-but-lookalike-xyz")
    probe.run(duration: 3)

    expect(probe.missing).to eq([])
    expect(Task.where(project: project).where("title LIKE 'drill-t1-%'").count).to eq(4)
  end
end
