# Runbook: failing over to the second region

> **Not usable yet.** There is no second region ([multi-region design](../aws/multi-region.md)). This is the procedure the design implies, written so the
> design can be judged and so a drill can start from something. **Every command here is unrun**; check each against current AWS documentation before
> trusting it, and rehearse in a non-production environment.

**When:** the primary region is impaired in a way that will not recover quickly (an AWS regional event, a failed deploy you cannot roll back, corrupted data you
cannot repair in place) and the cost of being down exceeds the cost of failing over. **Do not fail over** for a single bad deploy (roll back), a degraded dependency,
or a short AWS blip: failover has a cost (possible data loss, hours of failback work) and a bad failover is worse than a short outage.

**Decision owner:** the on-call lead, with a second person confirming. Announce in the incident channel before step 2.

## Planned switchover (no data loss; for drills and planned maintenance)

1. Scale the standby up to production size (Argo CD values for `prod-dr`; KEDA floors; wait for nodes and green pods).
2. `aws rds switchover-global-cluster --global-cluster-identifier <global> --target-db-cluster-identifier <secondary-cluster-arn>` (no data loss; the old primary becomes
   the secondary). Wait until the secondary is `available` and writable.
3. Point the application at the new writer: the standby pods already use the regional cluster endpoint (`DB_HOST`); verify with `bin/rails runner 'p ActiveRecord::Base.connection.select_value("select pg_is_in_recovery()")'` → `false`.
4. Move traffic: if you use failover records, fail the primary's health check on purpose (or set the primary record's weight to 0); otherwise edit the record.
5. Verify (below). 6. Scale the old primary region down.

## Unplanned failover (the primary is gone)

1. **Confirm and announce.** Is it the region or just your stack? (AWS Health Dashboard, a second vantage point.) Name the incident commander. Start a timeline.
2. **Stop writes in the old region if it is still partly alive**, so it cannot diverge: scale `api`, `worker` to 0 there (or block it at the WAF).
3. **Promote the database**, accepting data loss:
   `aws rds failover-global-cluster --global-cluster-identifier <global> --target-db-cluster-identifier <secondary-cluster-arn> --allow-data-loss`
   (verify the exact flags in the current CLI reference). Note the time: everything the old primary committed after the last replicated transaction is lost.
   Check how much: the secondary's `AuroraGlobalDBReplicationLag` just before the failure is the answer.
4. **Scale the standby up** to production size; wait for pods to be ready (`kubectl --context dr -n task-api get pods`). Run migrations only if the standby is behind (it should not be).
5. **Move traffic** (Route 53 failover does this on its own once the primary's health check fails; otherwise change the record). Lower the TTL beforehand if you can.
6. **Verify:** `/up` green on the standby's ALB; sign in; create a task with an attachment; download an attachment uploaded an hour ago (checks replication); `OutboxEvent.pending.count` falling
   ([event outbox](event-outbox.md): rows that had not been published replicated with the database and now go out from this region); the Notification service is consuming its queue here.
7. **Tell people** what was lost: changes in the last N seconds before the failure, attachments uploaded in the last minutes, notifications that may repeat or be missing.

## Failback (when the original region is healthy again)

Do not rush it, and do not do it during the incident. Rebuild the old region as the **secondary** of the new global cluster (it must re-sync from the new primary; its own
diverged data is discarded after you save anything worth reconciling from it), let replication catch up, then perform a **planned switchover** at a quiet time exactly as above.

## After

Blameless write-up within a week: timeline, RPO and RTO actually achieved against the targets, what the checklist missed, and updates to this page. If it was a drill, say so and treat the findings the same way.
