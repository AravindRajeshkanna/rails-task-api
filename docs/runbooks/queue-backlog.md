# Runbook: background job backlog or queue latency

**Alerts:** `task-api-<env>-queue-backlog`, `…-queue-depth-anomaly`, `…-queue-latency` (CloudWatch EMF series); `TaskApiQueueBacklog`,
`TaskApiQueueLatency`, `TaskApiNoWorkers`, `TaskApiFailedJobs` (Prometheus).
**Impact:** emails (while `NOTIFICATIONS_MODE=local`), webhooks, event publishing, embeddings and reminders are late. The API itself keeps working.

## What already happens by itself

KEDA adds `worker` pods (one per 50 waiting jobs, up to the environment's max). If the backlog alarm fires, the remediation Lambda
raises the worker floor, and a latency alarm restarts the workers. In `remediation_dry_run` mode it only says what it would do.
Look in the alert channel for its note.

## Triage

1. `kubectl -n task-api get scaledobject worker` and `get pods -l app.kubernetes.io/name=worker`. No pods, or all crash-looping?
   Probably a bad release: roll back (revert the tag commit).
2. **Which queue and which job?** Logs Insights:
   `filter event = "active_job.completed" | stats count(), max(duration_ms) by job_class | sort count() desc`
   A flood of one job class (a bulk import, an `EmbedTaskJob` backfill) explains the backlog.
3. **Are jobs failing and retrying?** Grafana → *Workers and failures*; `TaskApiFailedJobs` > 0 means retries are exhausted:
   ```sh
   kubectl -n task-api exec deploy/api -- bin/rails runner 'SolidQueue::FailedExecution.includes(:job).limit(10).each { |f| puts "#{f.job.class_name}: #{f.error.to_s[0,160]}" }'
   ```
4. **Is the database the bottleneck?** Workers poll it; see [high-latency](high-latency.md). The Solid Queue tables live in the `task_api_production_queue` database.

## Actions

| Cause | Do |
|---|---|
| Not enough workers, KEDA at max | Raise `keda.maxReplicaCount` in `deploy/gitops/envs/<env>/worker.yaml`; raise `JOB_CONCURRENCY` for more threads per pod only if CPU allows |
| A job fails every time | Fix or roll back; then retry the failed executions (`failed.retry`) or discard them |
| SNS publishing failing (events waiting in the outbox) | See [event-outbox.md](event-outbox.md): nothing is lost, they are sent when SNS recovers; check the topic ARN, the `worker` Pod Identity role and SNS health |
| Embedding backfill flooding the queue | Pause by scaling nothing: it is bounded by the AI budget; or pause the queue |
| No workers at all, jobs waiting | `kubectl rollout restart deploy/worker -n task-api`; check the liveness probe and `solid-queue` process title |

Separately, `…-notifications-dlq` > 0 means the **Notification service** gave up on an event: read it (see the setup guide's Day-2 table), fix the cause, redrive.
