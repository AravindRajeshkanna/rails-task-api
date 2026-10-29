# Observability and AIOps

## The three signals, joined by ids

| Signal | How it is produced | Where it goes | Joined by |
|---|---|---|---|
| **Logs** | `Rails.event`: domain events, `action_controller.request_completed` (the access log), job outcomes, `ai.completed`. JSON in production (`LOG_FORMAT`), one object per line | stdout → Fluent Bit (EKS add-on) → CloudWatch Logs | `request_id`, `user_id`, `trace_id`, `span_id` |
| **Metrics** | Prometheus from the same events, plus gauges read at scrape time (queue backlog, connection pool); `GET /metrics`, private to the cluster | kube-prometheus-stack → Grafana, Alertmanager | labels: controller, action, status, feature |
| **Traces** | OpenTelemetry (Rack, Rails, ActiveRecord, PG, Net::HTTP, AWS SDK, our `ai.*` spans with GenAI attributes), OTLP | collector → AWS X-Ray | `trace_id`, propagated across services (W3C and X-Ray headers) |

Turned on by `OTEL_EXPORTER_OTLP_ENDPOINT`; absent locally, so there is nothing to run for development. X-Ray needs trace ids that
start with a timestamp; the SDK is configured with the X-Ray id generator. Spans carry the user id, never names, emails or prompts.
Sampling: 10 % of new traces, always honouring the caller's decision (`OTEL_TRACES_SAMPLER_ARG`).

### Following one failure

1. Alert says the 5xx rate is high. Grafana "Task API": which `controller#action`.
2. CloudWatch Logs Insights, on the JSON logs:
   `filter event = "action_controller.request_completed" and status >= 500 | stats count() by controller, action`
3. Take a `trace_id` from a failing line: X-Ray shows the request across `api`, `ai`, `auth` and the database, with timings.
4. Same `trace_id` in the logs of every service shows what each did.

## Alerts and early AIOps

**Anomaly detection (CloudWatch, `observability.tf`).** Latency (p95 of target response time), error rate (5xx %), and
queue depth are each compared with a band learned from the metric's own history, including daily and weekly rhythm. So a 9 am
spike that is normal does not page, and a 3 am spike does. Static backstops cover hard limits: 5 % errors, 500 queued
jobs, a job older than 5 minutes, any failed job for 30 minutes, anything in the dead-letter queue, Aurora near its
capacity ceiling. Prometheus carries the finer-grained application alerts
(`deploy/observability/prometheus/task-api-rules.yaml`: AI error rate, AI spend, pool saturation, no workers).

Everything routes to one SNS topic (KMS-encrypted): PagerDuty (HTTPS integration), Slack (AWS Chatbot), email, and the two
AIOps Lambdas. `severity=page` in Prometheus means a human now; `ticket` means within the working day.

Amazon Lookout for Metrics, named in the roadmap, no longer exists (ended October 2025); see decision 18.

## Auto-remediation, in three layers

1. **Capacity (no AI, always on).** KEDA scales the `worker` Deployment on the queue backlog (one worker per 50 waiting jobs,
   up to 10) and the Notification consumers on SQS length. Karpenter adds nodes for pending pods, on Spot where it can.
2. **Safe actions (`remediate` Lambda).** Two alarms have a playbook:

   | Alarm | Action | Undone when |
   |---|---|---|
   | `…-queue-backlog` | double KEDA's `minReplicaCount` for `worker` (never past its maximum) | the alarm returns to OK |
   | `…-queue-latency` | rolling restart of `worker` | nothing to undo |

   Each is idempotent, cooled down for 15 minutes (the time of the last action is stored on the object it changed), limited by
   Kubernetes RBAC to *get/patch the named `worker` objects* (`aiops-rbac.yaml`), and announced on the alert topic.
   **It is a dry run until `remediation_dry_run = false`** in Terraform. Run it as a dry run in production for a few
   weeks: read what it says it would have done, then turn it on.
3. **Rollback (Argo Rollouts).** Production releases of `api` and `auth` are canaries (20 % → 50 % → 100 %) with an
   analysis that queries Prometheus for the success ratio and aborts the rollout automatically if it drops below 98 %.

## Root-cause analysis

When an alarm fires, the `rca` Lambda gathers: other alarms already firing, the 5xx error groups by `controller#action`,
error-level log events by type, deployments in the last hour (image tags and ages, from the Kubernetes API), and
slow or faulty X-Ray traces. It sends that to Bedrock through the same `ai_core` client as the product (`analyze_incident`
feature), and posts the validated result next to the alarm:

> **RCA: Workers stopped picking up jobs after the 14:02 deploy.** Likely cause (medium confidence): `worker:3fa91c2` rolled out
> 6 minutes before the alarm (`recent_deploys`) and no worker has claimed a job since (`error_log_events`: 14× `boot_failed`).
> Suggested next steps: 1. Roll back `worker` … 2. Check boot logs … Runbook: docs/runbooks/queue-backlog.md

It can only read and explain. Its output cannot trigger itself or the remediator (messages carry `kind=rca`, and both
Lambdas ignore them), concurrency is capped at 2, and it says plainly that it can be wrong. Log text is treated as
untrusted data in the prompt.

## Dashboards

- **Grafana "Task API"** (`deploy/observability/grafana`): traffic, errors, latency, slow endpoints, queue, workers, AI
  tokens, spend and latency, database pool.
- **CloudWatch "task-api-<env>"**: ALB latency/5xx, queue, Aurora, SQS, alarm states.
- **X-Ray service map** for dependencies.

## Chaos engineering

`enable_fis = true` creates two AWS Fault Injection Service experiments, which do nothing until started: delete one API pod,
and terminate one Karpenter node. Both stop automatically if the 5 % error alarm fires. Run them in staging with
the dashboard open; the question for each is "did users notice?" (They should not: PDBs, zone spreading, and Karpenter
exist for these cases.) The pod-delete experiment needs the `fis-experiment` RBAC from `cluster-config` (`fis.enabled`).
For vendor-neutral experiments, LitmusChaos works with the same chart and probes.

## Cost

Spot via Karpenter with consolidation; Graviton is a further ~20 % once CI builds multi-arch images; Aurora Serverless v2
scales from 0.5 ACU; one NAT gateway outside prod; VPC endpoints keep ECR/S3/Bedrock/SQS/SNS traffic off the NAT; AI budgets
cap per-tenant spend; an AWS Budget (80 % forecast, 100 % actual) and Cost Anomaly Detection post to the alert topic. After a
month of real usage: look at Compute Savings Plans for the steady on-demand base (the system node group, prod's critical
pool, Aurora) and right-size requests from Grafana.
