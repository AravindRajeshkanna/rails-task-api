# Runbook: failing over to the second region

> **Not yet rehearsed.** The Terraform and GitOps for a second region exist ([multi-region](../aws/multi-region.md)) but have never been applied, so **every command here
> is unrun**; check each against current AWS documentation before trusting it, and rehearse in a non-production environment first.
> What is automatic: when the primary load balancer fails its Route 53 health check (three failures, 30 s apart), DNS starts answering with the standby. What is not: promoting the
> database, scaling the standby up, promoting its secrets. **Terraform needs no change for a failover** (`dr_role` records how a stack was built, not who is serving), and nobody should
> `terraform apply` either stack during one.

**When:** the primary region is impaired in a way that will not recover quickly (an AWS regional event, a failed deploy you cannot roll back, corrupted data you
cannot repair in place) and the cost of being down exceeds the cost of failing over. **Do not fail over** for a single bad deploy (roll back), a degraded dependency,
or a short AWS blip: failover has a cost (possible data loss, hours of failback work) and a bad failover is worse than a short outage.

**Decision owner:** the on-call lead, with a second person confirming. Announce in the incident channel before step 2.

## Read-only mode (what clients see while the database cannot take writes)

The API has a read-only mode (`config/initializers/read_only_mode.rb`, [ADR 46](../decisions.md)): reads keep working, and every write answers `503 read_only` with `Retry-After: 30`; nothing was
changed, so clients retry as they are. Existing tokens keep working; signing in is a write and waits. Two ways in:

- **The database refuses.** Whenever Postgres answers a write with `read_only_sql_transaction` (a replica, or a writer that has just been demoted) the API turns it into the 503 instead of a 500. Nothing to set. This is what covers
  the window in unplanned step 5 below, where DNS has moved before the database is promoted.
- **`READ_ONLY=true`.** Refuses writes up front, without touching the database, in the process that has it. The standby renders with it on (`prod-dr` at standby size); rendering at production size
  (`SIZE_AS=prod`) turns it off, which is the promotion step's last action. To drain writes on a healthy region, render it on and sync: `READ_ONLY=true ruby deploy/scripts/render_gitops.rb prod tmp/prod-outputs.json`,
  commit, Sync. Render without it to turn it off again. It covers the API only: **workers keep running jobs**, so scale `worker` to 0 as well when the point is a clean cut.

Watch `taskapi_read_only_refusals_total{source="switch"|"database"}` and the `TaskApiReadOnly` alert (writes refused for 15 minutes). The cache degrades quietly meanwhile: counters stop counting (the
rate limits are not enforced by the API; the WAF's still are) and cached values are recomputed on every request.

## Planned switchover (no data loss; for drills and planned maintenance)

0. **Drain writes on the old primary**: render it with `READ_ONLY=true` (above), Sync, and scale its `worker` to 0. Wait until the outbox is empty (`OutboxEvent.pending.count`, [event outbox](event-outbox.md)): after the switchover those rows replicate, but a drained primary should have sent them.
1. Scale the standby up to production size: `SIZE_AS=prod ruby deploy/scripts/render_gitops.rb prod-dr tmp/prod-dr-outputs.json`, commit, Sync `prod-dr-*` in Argo CD (the canary and replica floors come back); wait for nodes and green pods.
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
4. **Scale the standby up** (this also turns its `READ_ONLY` off, so do it only once step 3 has finished): `SIZE_AS=prod ruby deploy/scripts/render_gitops.rb prod-dr tmp/prod-dr-outputs.json`, commit to `main`, Sync `prod-dr-*` in Argo CD (a Git host in the failed region would make this impossible: keep the sync reachable, see below), then `kubectl --context dr -n task-api get pods`. Run migrations only if the standby is behind (it should not be).
4a. **Promote its secrets** so they can be written (rotation, new values) now that the primary region cannot: for each of the five secrets under `task-api/prod/`, `aws secretsmanager stop-replication-to-replica --secret-id task-api/prod/<name> --region <standby>` (verify the command against the current CLI reference). Reading them already works without this.
5. **Move traffic.** Route 53 does this on its own once the primary's health check fails (alarm `task-api-prod-dns-failed-over`); it can be ahead of steps 3-4, in which case the standby answers with a read-only database for a few minutes: that is the window the planned order avoids, and the one [read-only mode](#read-only-mode-what-clients-see-while-the-database-cannot-take-writes) exists for (reads work, writes are `503 read_only`). To force it before the check trips on its own, invert the primary's health check: `aws route53 update-health-check --health-check-id <id> --inverted` (the id is `terraform output` of the primary's stack, or in the console).
6. **Verify:** `/up` green on the standby's ALB; `taskapi_read_only_refusals_total` has stopped rising; sign in; create a task with an attachment; download an attachment uploaded an hour ago (checks replication); `OutboxEvent.pending.count` falling
   ([event outbox](event-outbox.md): rows that had not been published replicated with the database and now go out from this region); the Notification service is consuming its queue here.
7. **Tell people** what was lost: changes in the last N seconds before the failure, attachments uploaded in the last minutes, notifications that may repeat or be missing.

## Failback (when the original region is healthy again)

Do not rush it, and do not do it during the incident.

1. **Let the old region come back as the secondary.** The global cluster still lists its cluster as a member; when the region recovers, Aurora re-syncs it from the new primary. Anything it committed that had not replicated
   is gone from the global cluster's point of view: save what is worth reconciling from its logs first. If the cluster itself was lost, recreate it by re-applying the primary's stack (its `aws_rds_global_cluster` already exists) after
   removing the dead cluster from the global cluster.
2. **S3 and images.** Both buckets replicate to each other, so objects uploaded to the standby during the incident are already flowing back. Images only replicate primary to standby: nothing was built during the incident, so there is nothing to bring back.
3. **Secrets.** If you promoted the standby's secrets (step 4a), decide which side is the source of truth and re-establish replication from it (`aws secretsmanager replicate-secret-to-regions`); do not leave two writable copies.
4. **Scale the old region up and verify it** while it still gets no traffic.
5. **Switch back** with the **planned switchover** above, at a quiet time. Then re-render the standby at its small size (`ruby deploy/scripts/render_gitops.rb prod-dr tmp/prod-dr-outputs.json`), commit and Sync.

## After

Blameless write-up within a week: timeline, RPO and RTO actually achieved against the targets, what the checklist missed, and updates to this page. If it was a drill, say so and treat the findings the same way.

## Things this runbook cannot fix in advance

- **Argo CD and Git.** Syncing the standby needs Argo CD (in the standby cluster, or the hub) to reach GitHub. If the failure also removes your path to either, the scale-up is `kubectl scale` and edits by hand; practise that once.
- **The Terraform state** of the primary lives in the primary's region. The standby's lives in its own, on purpose. Do not rely on the primary's state during an incident.
- **Anything not in Git or in a replicated store**: dashboards edited in the UI, Argo CD applications created by hand.
