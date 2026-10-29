# Runbook: events are not reaching the other services (the outbox is backing up)

**Alerts:** `task-api-<env>-event-outbox-stuck` (CloudWatch, `OutboxOldestAgeSeconds` > 300 s for 5 minutes) and `TaskApiEventOutboxStuck` (Prometheus,
`taskapi_outbox_oldest_pending_event_age_seconds`).
**Impact:** the Notification service hears about assignments, reminders and completions late, so emails and Slack posts are late. The API,
webhooks, the in-app inbox and real-time updates are not affected. **Nothing is lost:** every event is written to the `outbox_events` table in
the same transaction as the change, and is sent when SNS is reachable again. Duplicates are possible (delivery is at-least-once) and harmless,
because consumers deduplicate on the event id.

## How it works

A change that other services care about writes a row to `outbox_events` (the finished CloudEvents envelope) inside its own transaction.
After the commit, `OutboxRelayJob` is woken; it sends pending rows to SNS in batches and marks them `published_at`. It also runs every minute
to catch anything a wake-up missed. A row that cannot be sent keeps its `last_error`, counts `attempts`, and waits `2^attempts` seconds (at most
15 minutes) before the next try. A relay takes a 2-minute lease on a batch (`locked_until`), so two relays never send the same row, and a relay
that dies simply loses its lease. Published rows are deleted after 7 days.

## Triage

1. **How bad is it?** Grafana *Event outbox*, or:
   ```sh
   kubectl -n task-api exec deploy/api -- bin/rails runner 'p pending: OutboxEvent.pending.count, failing: OutboxEvent.pending.where("attempts > 0").count, oldest: OutboxEvent.pending.minimum(:created_at)'
   ```
2. **Why are they failing?** The error is on the row:
   ```sh
   kubectl -n task-api exec deploy/api -- bin/rails runner 'OutboxEvent.pending.where("attempts > 0").group(:last_error).count.each { |e, n| puts "#{n}  #{e}" }'
   ```
3. **Is the relay running at all?** Rows with `attempts = 0` that are old mean no relay is picking them up: the `outbox_relay` recurring task needs the `scheduler` process of `bin/jobs`; check the workers are up ([queue backlog](queue-backlog.md)) and that `EVENTS_SNS_TOPIC_ARN` is set on the worker.

## Actions

| `last_error` | Cause | Do |
|---|---|---|
| `Events::SnsPublisher::Retryable` (throttling, internal error, network) | SNS is slow or unreachable | Nothing: it backs off and retries; check the AWS status page. If it persists, check the VPC endpoint / NAT path from the worker pods |
| `AuthorizationErrorException` | The worker's Pod Identity role cannot publish to the topic | Fix the role (`deploy/terraform`, the `worker` pod identity); the backlog drains by itself afterwards |
| `NotFoundException` / `InvalidParameterException` for the topic | Wrong or deleted `EVENTS_SNS_TOPIC_ARN` | Correct the value and restart the workers |
| One event fails and others do not (`InvalidParameter`, message too large) | A poisoned row | Read it (`OutboxEvent.find(id).payload`); fix the producer, then delete the row: `OutboxEvent.find(id).destroy` (the other services will not get that one event) |

To push the backlog out now instead of waiting for the next try: `OutboxEvent.pending.update_all(available_at: Time.current)` then
`OutboxRelayJob.perform_now`. If you turn the outbox **off** (unset `EVENTS_SNS_TOPIC_ARN`), rows already written stay and are sent when it is
set again; events that happen while it is unset are not recorded.
