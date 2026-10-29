require "aws-sdk-sns"
require "json"
require "time"
require_relative "alarm"
require_relative "k8s"

module Aiops
  # Lambda handler: a small table of alarm -> safe, reversible action. Every action is
  #   * idempotent and cooled down (the last action's time is stored on the object it changed),
  #   * undone when the alarm returns to OK,
  #   * a no-op report while REMEDIATION_DRY_RUN is true (the default).
  # It can touch only what RBAC lets its Kubernetes group touch (deploy/k8s/platform/aiops-rbac.yaml).
  module Remediate
    COOLDOWN = 15 * 60
    ANNOTATION = "aiops.taskapi.dev"

    # alarm key (the alarm name without "task-api-<env>-") => action
    PLAYBOOK = {
      "queue-backlog" => :raise_worker_floor,
      "queue-latency" => :restart_workers
    }.freeze

    class << self
      def handler(event:, context: nil)
        alarm = Alarm.from_sns(event) or return { skipped: "not an alarm" }
        process(alarm)
      end

      def process(alarm, env: ENV, k8s: nil, sns: Aws::SNS::Client.new, now: Time.now.utc)
        action = PLAYBOOK[alarm.key(env.fetch("ENVIRONMENT"))] or return { skipped: "no runbook for #{alarm.name}" }
        dry_run = env.fetch("REMEDIATION_DRY_RUN", "true") != "false"
        k8s ||= K8s.new(cluster: env.fetch("CLUSTER_NAME"), region: env.fetch("AWS_REGION"))
        namespace = env.fetch("K8S_NAMESPACE", "task-api")

        outcome =
          if alarm.firing? then public_send(action, k8s, namespace, dry_run, now)
          elsif alarm.recovered? then restore(action, k8s, namespace, dry_run)
          else { skipped: "state #{alarm.state}" }
          end

        announce(sns, env["ALERTS_TOPIC_ARN"], alarm, action, outcome, dry_run)
        outcome
      end

      # More workers than the autoscaler would pick: raise KEDA's floor to double (never past the maximum).
      def raise_worker_floor(k8s, namespace, dry_run, now)
        path = "/apis/keda.sh/v1alpha1/namespaces/#{namespace}/scaledobjects/worker"
        object = k8s.get(path)
        annotations = object.dig("metadata", "annotations") || {}
        return { skipped: "cooling down" } if cooling_down?(annotations, now)

        current = object.dig("spec", "minReplicaCount") || 1
        maximum = object.dig("spec", "maxReplicaCount") || 10
        original = annotations["#{ANNOTATION}/original-min-replicas"] || current.to_s
        target = [ current * 2, maximum ].min
        return { skipped: "already at the maximum (#{maximum})" } if target == current

        unless dry_run
          k8s.merge_patch(path, { metadata: { annotations: { "#{ANNOTATION}/original-min-replicas" => original, "#{ANNOTATION}/last-action-at" => now.iso8601 } },
                                  spec: { minReplicaCount: target } })
        end
        { action: "raise_worker_floor", from: current, to: target, applied: !dry_run }
      end

      # Workers that are alive but not working: restart them (a rolling restart; jobs in flight are retried).
      def restart_workers(k8s, namespace, dry_run, now)
        path = "/apis/apps/v1/namespaces/#{namespace}/deployments/worker"
        annotations = k8s.get(path).dig("spec", "template", "metadata", "annotations") || {}
        return { skipped: "cooling down" } if cooling_down?(annotations, now)

        unless dry_run
          k8s.merge_patch(path, { spec: { template: { metadata: { annotations: { "kubectl.kubernetes.io/restartedAt" => now.iso8601, "#{ANNOTATION}/last-action-at" => now.iso8601 } } } } })
        end
        { action: "restart_workers", applied: !dry_run }
      end

      # Only the scale-up is reversible; a restart has nothing to undo.
      def restore(action, k8s, namespace, dry_run)
        return { skipped: "nothing to undo" } unless action == :raise_worker_floor

        path = "/apis/keda.sh/v1alpha1/namespaces/#{namespace}/scaledobjects/worker"
        original = k8s.get(path).dig("metadata", "annotations", "#{ANNOTATION}/original-min-replicas")
        return { skipped: "nothing to undo" } unless original

        k8s.merge_patch(path, { metadata: { annotations: { "#{ANNOTATION}/original-min-replicas" => nil } }, spec: { minReplicaCount: original.to_i } }) unless dry_run
        { action: "restore_worker_floor", to: original.to_i, applied: !dry_run }
      end

      private
        def cooling_down?(annotations, now)
          last = annotations["#{ANNOTATION}/last-action-at"]
          last && now - Time.parse(last) < COOLDOWN
        end

        def announce(sns, topic, alarm, action, outcome, dry_run)
          return unless topic

          verb = dry_run ? "WOULD HAVE" : "DID"
          sns.publish(
            topic_arn: topic, subject: "Auto-remediation (#{action}): #{alarm.name}"[0, 100],
            message: "#{dry_run ? '[dry run] ' : ''}#{verb} acted on #{alarm.name} (#{alarm.state}): #{outcome.to_json}",
            message_attributes: { "kind" => { data_type: "String", string_value: "rca" } } # not an alarm: neither Lambda re-processes it
          )
        end
    end
  end
end
