#!/usr/bin/env ruby
# frozen_string_literal: true

# Capacity arithmetic for the API (docs/capacity-planning.md): how many pods, and how many database connections, a given peak load needs.
#
#   ruby loadtest/capacity.rb --peak-rps 900
#   ruby loadtest/capacity.rb --peak-rps 900 --ceiling-rps 260 --threads 5 --workers 2 --acu 16
#
# The inputs are the measured numbers in docs/performance.md; the answer is only as good as they are for your traffic mix. It is arithmetic, not a forecast.
module Capacity
  # One Puma process with 5 threads, measured (docs/performance.md): the knee of the curve (p95 30 ms, no queueing) and the point it saturates.
  DEFAULTS = {
    peak_rps: nil,
    ceiling_rps: 260.0,   # requests per second one pod carries before latency starts to climb
    threads: 5,           # RAILS_MAX_THREADS, which is also the pod's database pool
    target: 0.7,          # run pods at this share of the ceiling at peak: the rest is for bursts, deploys and a lost pod
    spread: 3,            # availability zones; a zone can be lost, so the survivors must carry the peak
    workers: 2,           # worker pods (Solid Queue), each with JOB_CONCURRENCY processes of 3+1+2+1 threads (config/queue.yml)
    worker_threads: 7,
    acu: 16.0,            # Aurora Serverless v2 max ACU (db_max_acu)
    reserved: 20          # connections kept for migrations, consoles, monitoring, the replica's own and Solid Cache/Queue/Cable pools
  }.freeze

  Result = Struct.new(:pods, :pods_after_losing_a_zone, :database_connections, :max_connections, :connection_headroom, :requests_per_pod, keyword_init: true)

  module_function

  # Aurora PostgreSQL: LEAST(DBInstanceClassMemory / 9531392, 5000), where an ACU is 2 GiB. A published formula: check it for your engine version.
  def max_connections(acu) = [ (acu * 2 * 1024**3 / 9_531_392).floor, 5_000 ].min

  def plan(**given)
    inputs = DEFAULTS.merge(given)
    raise ArgumentError, "peak_rps is required" unless inputs[:peak_rps]

    pods = (inputs[:peak_rps] / (inputs[:ceiling_rps] * inputs[:target])).ceil
    provisioned = [ pods, pods_to_survive_a_zone(inputs) ].max
    connections = provisioned * inputs[:threads] + inputs[:workers] * inputs[:worker_threads] + inputs[:reserved]
    limit = max_connections(inputs[:acu])

    Result.new(pods: pods, pods_after_losing_a_zone: provisioned, database_connections: connections, max_connections: limit,
               connection_headroom: limit - connections, requests_per_pod: (inputs[:peak_rps].to_f / provisioned).round(1))
  end

  # Losing one zone's share of the pods must still leave enough: the survivors may run up to 90% of the ceiling in an emergency.
  def pods_to_survive_a_zone(inputs)
    surviving = (inputs[:peak_rps] / (inputs[:ceiling_rps] * 0.9)).ceil
    (surviving * inputs[:spread].to_f / (inputs[:spread] - 1)).ceil
  end

  def report(result, inputs)
    warn_line = result.connection_headroom.negative? ? "\n  !! The database cannot take this many connections: raise the ACU ceiling, add a pooler (RDS Proxy or PgBouncer), or reduce threads." : ""
    <<~TEXT
      peak load            #{inputs[:peak_rps]} requests/s
      pods at 70% of ceiling   #{result.pods}
      pods to survive losing one of #{inputs.fetch(:spread, DEFAULTS[:spread])} zones   #{result.pods_after_losing_a_zone}  (#{result.requests_per_pod} requests/s each at peak)
      database connections #{result.database_connections} of #{result.max_connections} allowed (#{result.connection_headroom} spare)#{warn_line}
    TEXT
  end
end

if $PROGRAM_NAME == __FILE__
  require "optparse"
  options = {}
  OptionParser.new do |parser|
    parser.banner = "usage: ruby loadtest/capacity.rb --peak-rps N [options]"
    { peak_rps: Float, ceiling_rps: Float, threads: Integer, target: Float, spread: Integer, workers: Integer, worker_threads: Integer, acu: Float, reserved: Integer }.each do |key, type|
      parser.on("--#{key.to_s.tr('_', '-')} VALUE", type) { |value| options[key] = value }
    end
  end.parse!
  abort "usage: ruby loadtest/capacity.rb --peak-rps N [options]" unless options[:peak_rps]

  puts Capacity.report(Capacity.plan(**options), options)
end
