require "json"
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "ai_core"
require "aiops/alarm"

module AiopsHelpers
  # An SNS event carrying a CloudWatch alarm state change.
  def alarm_event(name: "task-api-prod-queue-backlog", state: "ALARM", old: "OK", attributes: {}, message: nil)
    body = message || { "AlarmName" => name, "NewStateValue" => state, "OldStateValue" => old, "NewStateReason" => "Threshold Crossed: 1 datapoint [812.0] was greater than 500.0",
                        "StateChangeTime" => "2026-10-29T12:00:00.000+0000", "Trigger" => { "MetricName" => "QueueDepth", "Namespace" => "TaskApi" } }
    { "Records" => [ { "Sns" => { "Message" => body.is_a?(String) ? body : body.to_json, "MessageAttributes" => attributes } } ] }
  end

  def sns_client = Aws::SNS::Client.new(stub_responses: true, region: "us-east-1")

  def published(sns) = sns.api_requests.select { |request| request[:operation_name] == :publish }.map { |request| request[:params] }
end

# Records what would be sent to the Kubernetes API; serves canned objects.
class FakeK8s
  attr_reader :patches

  def initialize(objects = {})
    @objects = objects
    @patches = []
  end

  def get(path) = @objects.fetch(path) { raise "unexpected GET #{path}" }

  def merge_patch(path, body)
    @patches << [ path, body ]
    deep_merge!(@objects.fetch(path), JSON.parse(body.to_json))
  end

  private
    def deep_merge!(target, patch)
      patch.each do |key, value|
        if value.nil? then target.delete(key)
        elsif value.is_a?(Hash) then deep_merge!(target[key] ||= {}, value)
        else target[key] = value
        end
      end
    end
end

RSpec.configure { |config| config.include AiopsHelpers }
