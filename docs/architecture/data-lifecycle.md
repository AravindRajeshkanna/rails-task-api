# Data lifecycle: what grows, how it leaves, and who owns each row

Three questions that decide how the database ages: which tables grow without limit and how fast, what we would do about it and when, and, if one database ever stops being enough, which rows belong to whom. The last is written down as a test (`spec/db/tenant_ownership_spec.rb`) so it cannot go stale. Decisions: [ADR 67](../decisions.md). Personal-data retention: [data-protection.md](../data-protection.md). Capacity of the database today: [capacity-planning.md](../capacity-planning.md).

## What grows

Row sizes were measured by creating realistic rows through the models, not guessed: `pg_column_size` for the row, `pg_total_relation_size` for the row with its indexes. They are inputs to arithmetic, not forecasts.

| Table | Grows with | Row (heap) | Row with indexes | Bounded by |
| --- | --- | --- | --- | --- |
| `audit_events` | every audited create/update/discard (tasks, projects, memberships, organizations, teams, invitations) | 355 B | 640 B (5 indexes) | **nothing** |
| `webhook_deliveries` | events x webhooks listening | 940 B (a task snapshot) | | 30 days |
| `ai_usages` | AI calls (no prompt text) | not measured | | **nothing**; far smaller and slower-growing than the audit trail |
| `tasks` | product use | | 677 B (149,000 rows, load-test data) | archive, then purge after 30 days |
| `comments` | product use | | 156 B (37,000 rows) | with the task |
| `notifications` | events x recipients | | | 30 / 180 days |
| `outbox_events` | every domain event | | | 7 days after publish |
| `sessions`, `idempotency_keys` | sign-ins, create requests | 152 B (session) | | 30 days (14 idle) / 24 hours |

Two tables have no bound: the audit trail, which is large and permanent on purpose, and the AI usage ledger, which is small. Everything else that grows with traffic has a job that removes it ([data-protection.md](../data-protection.md#retention-enforced)). Three of them did not until this change (webhook deliveries, concluded invitations, and the Notification service's delivery log); the audit found them by listing every table against the jobs that prune it.

### Arithmetic, with the inputs marked

`audit_events` at 640 bytes a row, with an illustrative rate you should replace with your own:

| Audited changes per day | Per year | 
| --- | --- |
| 100,000 | 23 GB |
| 1,000,000 | 233 GB |

It is the table to watch because it never shrinks. Query the real rate with `SELECT date_trunc('day', created_at), count(*) FROM audit_events GROUP BY 1 ORDER BY 1 DESC LIMIT 30`.

## Archival: audit events, when it is time

**Not built, because there is no evidence yet that it buys anything.** A table of tens of gigabytes is unremarkable for PostgreSQL, the trail is read by `(project_id, created_at)` and `(organization_id, created_at)` indexes that stay efficient, and a partitioned table is more to operate. The plan is written so that it can be executed without a design session.

**Triggers** (placeholders chosen like the SLO targets: revisit with real numbers): the table plus its indexes passes about 50 GB; or vacuum/backup/restore time of the whole database is dominated by it; or a retention policy is set that is shorter than "forever" (then archiving becomes deleting after a copy, and the reason is a requirement, not size).

**Shape.** Range-partition `audit_events` by month on `created_at`; make the primary key `(id, created_at)` (PostgreSQL requires the partition key in every unique constraint; Rails 8 supports composite primary keys). Create next month's partition ahead of time from a scheduled job. Archive a partition by `DETACH PARTITION ... CONCURRENTLY`, dumping it to object storage, then dropping it. The cost is a one-time rewrite of the table to partition it, which is why to do it *before* it is large, in a maintenance window or with a backfill and swap; the same migration discipline as [zero-downtime-migrations](../runbooks/zero-downtime-migrations.md) applies.

**Reading the archive.** Not through the API. An archived month is restored into an analysis database on demand. Say so to whoever relies on the trail, and keep the audit endpoints' documented window honest: they show what is in the live table.

**Careful.** The dumps bucket expires objects after `dump_retention_days` (90). An archive needs its own bucket or prefix without that rule, with the same encryption and no public access; otherwise "archived" means "deleted in 90 days".

**Not archival.** Tasks are soft-deleted and purged after 30 days; there is no tiering of old, finished tasks, and none is needed while they are indexed by project and status. Attachments could move to Infrequent Access with an S3 lifecycle rule (a Terraform change, not done).

## Who owns each row: the tenant map

The tenant is the **organization**. `spec/db/tenant_ownership_spec.rb` classifies every table and fails when a new table is added without a decision; it also checks that the column it names is a real foreign key. Summary:

| Owner | Tables | Reaches the owner through |
| --- | --- | --- |
| **organization** | `organizations`, `organization_memberships`, `organization_invitations`, `teams`, `team_memberships`, `projects` | `organization_id` (`team_id` for team memberships). **`projects.organization_id` is nullable**: a personal project has none |
| **project** | `project_teams`, `memberships`, `tasks`, `comments`, `tags`, `taggings`, `webhooks`, `webhook_deliveries`, `notifications`, `ai_usages`, `audit_events` | `project_id` (through `task_id` or `webhook_id` for comments, taggings and deliveries). `ai_usages.project_id` and `audit_events.project_id` are nullable |
| **user** | `users`, `sessions`, `notification_settings`, `notification_mutes`, `idempotency_keys` | `user_id`; they follow a person across organizations |
| **platform** | `active_storage_blobs`, `active_storage_variant_records`, `outbox_events` | no tenant. (`active_storage_attachments` is polymorphic: the owner is the record it names) |

The code has one place that answers "which organization is this record in": `Tenant.organization_id_for` ([ADR 62](../decisions.md)). Limits, budgets and log fields are keyed by it, which is what makes the boundary real rather than a diagram.

## If one database ever stops being enough

**Not recommended now, and nothing here is a plan to do it.** The levers come in this order, each cheaper and more reversible than the next, and the load test says where each one runs out:

1. **Retention and archival** (above): done except the audit trail.
2. **Read replica** for the heavy reads: done ([ADR 60](../decisions.md)).
3. **A bigger writer**: raise the Aurora ACU ceiling; the connection limit moves with it ([capacity-planning.md](../capacity-planning.md)).
4. **A connection pooler** in front of the writer, if pods multiply faster than the writer's connections.
5. **Partition large tables inside the one database** (by time for the audit trail; by hash of `project_id` for `tasks`), which gets most of the maintenance benefit with none of the distribution.
6. **Split by organization** across databases. Only with evidence that 1 to 5 are exhausted: sustained writer saturation at peak that the load test cannot buy back with a larger instance.

What stands in the way of 6, read off the map:

- **Personal projects have no organization.** Every one needs a home (a personal organization per user, backfilled) before any row can be placed. `Tenant.organization_id_for` returns `nil` for them today, and they are limited per person.
- **People cross tenants.** `users`, `sessions`, settings and idempotency keys are user-owned, and a person can belong to several organizations. Identity must live in one global place: the Auth service already is that in JWT mode; in local mode the `users` table is it. A session token's digest must resolve to a user without knowing the shard.
- **The inbox is read by a person and owned by a project.** "My notifications across organizations" becomes a fan-in over shards, or a per-person store written by each shard's events.
- **Cross-tenant reads exist.** The activity feed, search and the project list are queries across all of a person's projects; with several organizations they become scatter-gather.
- **Ids collide.** Every database counts from 1. Ids appear in URLs and GlobalIDs, so they would need to be unique across shards (a range per shard, or ids that carry the shard).
- **Global uniqueness.** `users.email_address` and `sessions.token_digest` are unique across everything; a shard cannot enforce that alone.

What is ready: every request path sets the organization (`Current.organization_id`), the budgets and rate limits are per organization, the isolation test hits every route as an outsider, and the map above is machine-checked. What is not: all of the list.
