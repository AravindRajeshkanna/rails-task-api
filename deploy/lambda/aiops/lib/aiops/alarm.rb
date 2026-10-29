require "json"

module Aiops
  # A CloudWatch alarm state change, as delivered by SNS. Other messages on the alerts topic (ECR findings,
  # AWS Health, budget notices, our own RCA posts) are not alarms and are ignored.
  Alarm = Struct.new(:name, :state, :previous_state, :reason, :changed_at, :metric, :namespace, keyword_init: true) do
    def self.from_sns(event)
      record = event.dig("Records", 0, "Sns") or return
      return if record.dig("MessageAttributes", "kind", "Value") == "rca" # our own output: never re-analyze it

      body = JSON.parse(record.fetch("Message"))
      return unless body.is_a?(Hash) && body["AlarmName"]

      new(
        name: body["AlarmName"], state: body["NewStateValue"], previous_state: body["OldStateValue"], reason: body["NewStateReason"],
        changed_at: body["StateChangeTime"], metric: body.dig("Trigger", "MetricName"), namespace: body.dig("Trigger", "Namespace")
      )
    rescue JSON::ParserError, KeyError
      nil
    end

    def firing? = state == "ALARM"
    def recovered? = state == "OK"

    # "task-api-prod-queue-backlog" -> "queue-backlog" (what the runbook table is keyed by)
    def key(environment) = name.delete_prefix("task-api-#{environment}-")
  end
end
