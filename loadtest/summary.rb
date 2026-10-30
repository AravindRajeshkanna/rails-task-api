#!/usr/bin/env ruby
# Turns a k6 `--summary-export` file into a Markdown report (for the GitHub step summary and the logs).
#
#   ruby loadtest/summary.rb tmp/loadtest/summary.json [rate]
#
# Prints the latency of every endpoint, and lists any threshold that was breached. Exits 1 if one was.
require "json"

path, rate = ARGV
abort "usage: summary.rb summary.json [rate]" unless path && File.exist?(path)

metrics = JSON.parse(File.read(path)).fetch("metrics")
trend = ->(name) { metrics[name] }
ms = ->(value) { value.nil? ? "-" : format("%.0f", value) }

endpoints = metrics.keys.filter_map { |key| key[/\Ahttp_req_duration\{name:(.+)\}\z/, 1] }.sort
reads = trend.call("http_req_duration{kind:read}")
writes = trend.call("http_req_duration{kind:write}")

puts "### Load test#{rate ? " at #{rate} visits/s" : ''}", ""
puts "| Endpoint | median | p90 | p95 | p99 | max |", "| --- | ---: | ---: | ---: | ---: | ---: |"
endpoints.each do |name|
  row = trend.call("http_req_duration{name:#{name}}")
  puts "| `#{name}` | #{ms.call(row['med'])} | #{ms.call(row['p(90)'])} | #{ms.call(row['p(95)'])} | #{ms.call(row['p(99)'])} | #{ms.call(row['max'])} |"
end
puts "| **all reads** | #{ms.call(reads&.dig('med'))} | #{ms.call(reads&.dig('p(90)'))} | #{ms.call(reads&.dig('p(95)'))} | #{ms.call(reads&.dig('p(99)'))} | #{ms.call(reads&.dig('max'))} |" if reads
puts "| **all writes** | #{ms.call(writes&.dig('med'))} | #{ms.call(writes&.dig('p(90)'))} | #{ms.call(writes&.dig('p(95)'))} | #{ms.call(writes&.dig('p(99)'))} | #{ms.call(writes&.dig('max'))} |" if writes
puts "", "Latencies in milliseconds."

failed = metrics.dig("http_req_failed", "value")
dropped = metrics.dig("dropped_iterations", "count") || 0
puts "", "Failed requests: #{failed ? format('%.2f%%', failed * 100) : '-'}. Dropped iterations: #{dropped}."

breached = metrics.flat_map { |name, values| (values["thresholds"] || {}).select { |_expression, breached| breached == true }.keys.map { |expression| "#{name} #{expression}" } }
if breached.empty?
  puts "", "All thresholds held."
else
  puts "", "**Thresholds breached:**", *breached.map { |line| "- `#{line}`" }
  exit 1
end
