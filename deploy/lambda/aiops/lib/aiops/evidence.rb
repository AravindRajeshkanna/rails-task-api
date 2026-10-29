require "aws-sdk-cloudwatch"
require "aws-sdk-cloudwatchlogs"
require "aws-sdk-xray"
require "time"

module Aiops
  # Gathers what an engineer would look at first, in bounded form. Each collector is independent: one failing
  # (missing permission, no data) leaves a note instead of failing the analysis.
  class Evidence
    WINDOW = 15 * 60

    def initialize(environment:, cluster:, log_group:, k8s: nil, logs: Aws::CloudWatchLogs::Client.new, cloudwatch: Aws::CloudWatch::Client.new, xray: Aws::XRay::Client.new, namespace: "task-api")
      @environment = environment
      @cluster = cluster
      @log_group = log_group
      @k8s = k8s
      @logs = logs
      @cloudwatch = cloudwatch
      @xray = xray
      @namespace = namespace
    end

    def collect(alarm, now: Time.now.utc)
      {
        "other_alarms_firing" => safely("other_alarms_firing") { other_alarms(alarm) },
        "error_groups_5xx" => safely("error_groups_5xx") { insights("filter event = 'action_controller.request_completed' and status >= 500 | stats count(*) as errors by controller, action | sort errors desc | limit 8", now) },
        "error_log_events" => safely("error_log_events") { insights("filter level = 'ERROR' | stats count(*) as occurrences by event, service | sort occurrences desc | limit 8", now) },
        "recent_deploys" => safely("recent_deploys") { recent_deploys(now) },
        "slow_or_faulty_traces" => safely("slow_or_faulty_traces") { traces(now) }
      }
    end

    private
      def safely(name)
        yield || "none found"
      rescue => error
        "unavailable (#{name}: #{error.class.name.split('::').last})"
      end

      def other_alarms(alarm)
        names = @cloudwatch.describe_alarms(alarm_name_prefix: "task-api-#{@environment}-", state_value: "ALARM").metric_alarms.map(&:alarm_name) - [ alarm.name ]
        names.empty? ? nil : names
      end

      # CloudWatch Logs Insights over the JSON app logs; polls briefly.
      def insights(query, now)
        id = @logs.start_query(log_group_name: @log_group, start_time: (now - WINDOW).to_i, end_time: now.to_i, query_string: query).query_id
        10.times do
          result = @logs.get_query_results(query_id: id)
          if %w[Complete Failed Cancelled Timeout].include?(result.status)
            rows = result.results.map { |row| row.to_h { |field| [ field.field, field.value ] }.except("@ptr") }
            return rows.empty? ? nil : rows
          end
          sleep(2) unless ENV["AIOPS_NO_SLEEP"]
        end
        nil
      end

      def recent_deploys(now)
        return "unavailable (no cluster access configured)" unless @k8s

        replicasets = @k8s.get("/apis/apps/v1/namespaces/#{@namespace}/replicasets")["items"]
        recent = replicasets.select { |rs| Time.parse(rs.dig("metadata", "creationTimestamp")) > now - 3600 }
        recent.map { |rs|
          { "workload" => rs.dig("metadata", "ownerReferences", 0, "name"), "image" => rs.dig("spec", "template", "spec", "containers", 0, "image").to_s.split("/").last,
            "minutes_ago" => ((now - Time.parse(rs.dig("metadata", "creationTimestamp"))) / 60).round }
        }.then { |list| list.empty? ? nil : list }
      end

      def traces(now)
        summaries = @xray.get_trace_summaries(start_time: now - WINDOW, end_time: now, filter_expression: "fault OR responsetime > 3", sampling: false).trace_summaries
        return nil if summaries.empty?

        summaries.first(5).map { |trace| { "id" => trace.id, "duration_s" => trace.duration&.round(2), "fault" => trace.has_fault, "http" => trace.http&.http_url.to_s.sub(/\?.*/, "") } }
      end
  end
end
