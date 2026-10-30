#!/usr/bin/env ruby
# frozen_string_literal: true

# Measures a failover drill from the client's side (docs/runbooks/failover-drill.md). Once a second it reads a project and creates a task,
# records what came back, and when it stops it checks which of the tasks the API acknowledged are still there. From that it reports:
#
#   * how long reads and writes were unavailable (the RTO a user would have felt: from the first failure to the first tick where both worked),
#   * what the API said meanwhile (503 read_only, 502 from the load balancer, connection errors),
#   * how many acknowledged writes were lost (the RPO, in rows).
#
#   PROBE_TOKEN=<bearer token> ruby deploy/scripts/drill_probe.rb https://api.staging.example.com <project id> [seconds]
#
# Run it from outside the cluster, against the public name, for the whole drill; Ctrl-C ends it early and still prints the report. It
# creates tasks titled "drill-<run>-<n>" in that project (use a throwaway one) and never changes or deletes anything else.
require "json"
require "net/http"
require "securerandom"
require "time"

module DrillProbe
  Sample = Struct.new(:at, :seq, :read, :write, keyword_init: true) # read/write: an HTTP status, or :error for no answer

  # A tiny HTTP client that never raises: a connection error is an answer too, and is exactly what a drill produces.
  class Client
    def initialize(base_url, token, timeout: 5)
      @base = URI(base_url)
      @token = token
      @timeout = timeout
    end

    def get(path) = request(Net::HTTP::Get.new(path))

    def post(path, body)
      request(Net::HTTP::Post.new(path).tap do |post|
        post["Content-Type"] = "application/json"
        post.body = JSON.generate(body)
      end)
    end

    private
      def request(request)
        request["Authorization"] = "Bearer #{@token}"
        request["Accept"] = "application/json"
        http = Net::HTTP.new(@base.host, @base.port)
        http.use_ssl = @base.scheme == "https"
        http.open_timeout = http.read_timeout = @timeout
        response = http.request(request)
        [ response.code.to_i, response.body.to_s ]
      rescue StandardError
        [ :error, "" ]
      end
  end

  class Probe
    attr_reader :samples, :acknowledged, :run_id

    def initialize(client:, project_id:, run_id: SecureRandom.hex(3), clock: -> { Process.clock_gettime(Process::CLOCK_REALTIME) }, sleeper: ->(seconds) { sleep(seconds) })
      @client = client
      @project_id = project_id
      @run_id = run_id
      @clock = clock
      @sleeper = sleeper
      @samples = []
      @acknowledged = [] # titles the API answered 201 for
    end

    def tick
      seq = @samples.size + 1
      at = @clock.call
      read, = @client.get("/api/v1/projects/#{@project_id}")
      title = "drill-#{@run_id}-#{seq}"
      write, = @client.post("/api/v1/projects/#{@project_id}/tasks", { title: title })
      @acknowledged << title if write == 201
      @samples << Sample.new(at: at, seq: seq, read: read, write: write)
    end

    def run(duration:, interval: 1)
      deadline = @clock.call + duration
      while @clock.call < deadline
        started = @clock.call
        tick
        @sleeper.call([ interval - (@clock.call - started), 0 ].max)
      end
    end

    # The acknowledged tasks that are no longer there. Retries for a while, because the first reads after a failover may themselves fail.
    def missing(attempts: 30)
      attempts.times do
        found = fetch_titles
        return @acknowledged - found if found
        @sleeper.call(2)
      end
      nil # could not read the project at all
    end

    private
      def fetch_titles
        titles = []
        page = 1
        loop do
          status, body = @client.get("/api/v1/projects/#{@project_id}/tasks?q=drill-#{@run_id}-&limit=100&page=#{page}")
          return nil unless status == 200

          json = JSON.parse(body)
          titles.concat(json.fetch("data").map { |task| task.fetch("title") })
          return titles if page >= json.dig("meta", "pages").to_i

          page += 1
        end
      end
  end

  class Report
    def initialize(samples, acknowledged:, missing:, run_id:)
      @samples = samples
      @acknowledged = acknowledged
      @missing = missing
      @run_id = run_id
    end

    # Runs of consecutive failures: [{ from:, to:, ticks:, statuses: }], where `to` is the first success after (nil if it never recovered).
    def outages(kind)
      outages = []
      current = nil
      @samples.each do |sample|
        failed = failed?(sample, kind)
        if failed
          current ||= { from: sample.at, to: nil, ticks: 0, statuses: Hash.new(0) }
          current[:ticks] += 1
          current[:statuses][status_for(sample, kind)] += 1
        elsif current
          outages << current.merge(to: sample.at)
          current = nil
        end
      end
      outages << current if current
      outages
    end

    # What a user would have felt: from the first failing tick (read or write) to the first later tick where both worked.
    def time_to_full_service
      first_failure = @samples.index { |sample| failed?(sample, :read) || failed?(sample, :write) }
      return 0.0 unless first_failure

      recovered = @samples[first_failure..].find { |sample| !failed?(sample, :read) && !failed?(sample, :write) }
      recovered && (recovered.at - @samples[first_failure].at)
    end

    def to_s
      lines = []
      span = @samples.empty? ? 0 : @samples.last.at - @samples.first.at
      lines << "Drill probe #{@run_id}: #{@samples.size} ticks over #{format('%.0f', span)} s"
      %i[read write].each { |kind| lines.concat(describe(kind)) }
      full = time_to_full_service
      lines << "time to full service: #{full.nil? ? 'NOT RECOVERED by the end of the run' : "#{format('%.1f', full)} s (first failure to the first tick where reads and writes both worked)"}"
      lines << if @missing.nil?
        "acknowledged writes lost: UNKNOWN (the project could not be read at the end), #{@acknowledged.size} were acknowledged"
      else
        "acknowledged writes lost: #{@missing.size} of #{@acknowledged.size} (the RPO in rows)#{@missing.empty? ? '' : ": #{@missing.first(10).join(', ')}#{@missing.size > 10 ? ', ...' : ''}"}"
      end
      lines.join("\n")
    end

    private
      def failed?(sample, kind) = !(kind == :read ? sample.read == 200 : sample.write == 201)

      def status_for(sample, kind) = kind == :read ? sample.read : sample.write

      def describe(kind)
        failing = @samples.count { |sample| failed?(sample, kind) }
        label = kind == :read ? "reads " : "writes"
        lines = [ "#{label}: #{@samples.size - failing} ok, #{failing} failed" ]
        outages(kind).each_with_index do |outage, index|
          ends = outage[:to] ? "#{format('%.1f', outage[:to] - outage[:from])} s" : "not recovered"
          lines << "  outage #{index + 1}: #{Time.at(outage[:from]).utc.strftime('%H:%M:%S')} UTC, #{ends}, #{outage[:ticks]} failed ticks, answers #{outage[:statuses].inspect}"
        end
        lines
      end
  end

  def self.main(argv, env: ENV)
    base_url, project_id, seconds = argv
    token = env["PROBE_TOKEN"]
    abort "usage: PROBE_TOKEN=<token> #{$PROGRAM_NAME} <base url> <project id> [seconds, default 600]" unless base_url && project_id && token

    probe = Probe.new(client: Client.new(base_url, token), project_id: project_id)
    puts "Probing #{base_url}, project #{project_id}, run #{probe.run_id}. Ctrl-C ends the run and prints the report."
    begin
      probe.run(duration: (seconds || 600).to_f)
    rescue Interrupt
      puts "\ninterrupted"
    end
    puts "Checking which acknowledged tasks survived..."
    puts Report.new(probe.samples, acknowledged: probe.acknowledged, missing: probe.missing, run_id: probe.run_id)
  end
end

DrillProbe.main(ARGV) if $PROGRAM_NAME == __FILE__
