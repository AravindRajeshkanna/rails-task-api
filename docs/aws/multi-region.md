# Multi-region: a design, not a build

**Status: designed, not built, not run.** Nothing here has been applied to AWS, and neither has the single-region platform it would extend. Terraform for
a second region would be several hundred lines that `terraform validate` can check but only a real account can prove, written for a primary that has not
yet run. [ADR 42](../decisions.md) explains why that was the wrong thing to ship first. This page is the plan to follow once one region has run in anger,
and [the failover runbook](../runbooks/regional-failover.md) is the procedure it would need.

## What it would be

**Active/passive, warm standby.** One region serves all traffic. A second holds a continuously replicated copy of the data and a scaled-down copy of the
platform, and takes over on command (or on a failed health check, if you accept automatic failover; the recommendation below is not to).
Active/active is not proposed: it needs conflict-free writes, and every write path here (tasks, memberships, sessions, the outbox) assumes one database.

| Goal | Value to aim for | Honest range |
|---|---|---|
| **RPO** (data lost) | seconds | Aurora Global Database replication lag is typically under a second, but an *unplanned* failover accepts whatever had not replicated. Zero is not available |
| **RTO** (time to serve again) | 15-30 minutes | Dominated by promoting the database (a few minutes), scaling the standby up (Karpenter needs nodes), and people deciding. Automated, rehearsed failover can approach 5-10 minutes; unrehearsed, plan on an hour |

These are targets to verify in a drill, not measurements.

## Component by component

| Component | In the second region | How | What is lost or different |
|---|---|---|---|
| **DNS** | One name, two answers | Route 53 *failover* records for `api.<domain>` with a health check on `https://api.<domain>/up`; TTL 60 s | Resolvers that cache longer take longer to move |
| **Network, EKS, Karpenter, Argo CD** | The same Terraform root module applied again with its own state and `region` | `envs/prod-dr.tfvars` + `envs/prod-dr.backend.hcl`; Argo CD's ApplicationSet cluster generator targets clusters labelled `role=dr` (the hub-and-spoke shape in [ADR 26](../decisions.md)) | Standby runs at minimum scale (API 1, worker 1, KEDA floor 0); scale-up is part of failover |
| **Database** | Aurora **Global Database**: a read-only secondary cluster in region B | `aws_rds_global_cluster` wrapping the primary; the secondary cluster joins it (`global_cluster_identifier`, no master credentials). Every database on the cluster replicates: primary, Solid Queue, Solid Cache, Solid Cable, `auth`, `notifications` | Replication is asynchronous (RPO above). The standby is read-only until promoted. `manage_master_user_password` is per cluster: after promotion the secret that matters is the secondary's |
| **Object storage** (attachments, avatars) | A replica bucket | S3 Cross-Region Replication (versioning is already on); the app reads `ACTIVE_STORAGE_BUCKET` and region from the environment | Objects written seconds before the failure may be missing; CRR is eventually consistent (S3 Replication Time Control narrows it to 15 minutes, with an SLA) |
| **Container images** | Same images | ECR registry replication rule to region B | New images take a moment to appear there; deploy to the standby from the replicated tag |
| **Secrets** | Replicas | Secrets Manager multi-Region secrets (`replica` blocks), including the JWKS signing keys, so tokens issued before the failover still verify | Rotating a secret replicates; a regional KMS key per replica |
| **Events** | An SNS topic and SQS queues per region (they are regional and cheap) | The same Terraform; subscriptions are within a region | See below: this is where the outbox pays off |
| **Bedrock, SES** | Enabled in region B | Model access and verified identities are per region; `bedrock_model_id` may be a different inference profile | Forgetting these is the classic failover surprise |
| **Observability** | Per-region Prometheus/CloudWatch, one Grafana | The same stack applied again | A regional outage takes that region's metrics with it; alarm from outside (Route 53 health check) |

## How the work done so far helps

- **The transactional outbox** ([ADR 41](../decisions.md)). Unpublished events are rows in the database, so they replicate with it and the surviving
  region's relay publishes them. Without it, events in flight at the moment of failure would be gone. Events already published into the failed region's SQS
  queue die with that region (queues do not replicate); the Notification service deduplicates on event id, so a replayed event is harmless, but one that
  was published and not yet *delivered as email* may be lost or, because its dedupe table is regional too, delivered twice. Both are accepted.
- **Idempotent consumers and deterministic reminder ids**: replays are safe.
- **Tokens in the database, keys in Secrets Manager**: sessions and JWTs survive the move if both replicate.
- **Zero-downtime migrations** ([runbook](../runbooks/zero-downtime-migrations.md)): they matter more, not less, because a global cluster has one writer.

## What would have to change in the code and configuration

1. **Per-region settings as environment, not constants.** `AWS_REGION`, the bucket, `EVENTS_SNS_TOPIC_ARN`, `DB_HOST`: already read from the environment. The Helm values per
   environment (`deploy/gitops/envs/<env>/`) gain a `prod-dr` entry; nothing in the application is region-aware.
2. **A read-only switch** for the standby and for the promotion window (writes to a read-only Aurora secondary fail with `PG::ReadOnlySqlTransaction`, which is a `500`
   today). A few lines of middleware answering `503 read_only` with `Retry-After` would turn that into a clean message. Not built; add it when the first drill shows it matters.
3. **Terraform**: variables `dr_region`, `dr_role` (`none|primary|secondary`); in `database.tf` the global cluster (primary) or the joined secondary; `replica` blocks in
   `secrets.tf`; CRR and the replica bucket in `storage.tf`; a replication rule in `ecr.tf`; failover records and a health check in `edge.tf`. The existing `alb_exists`
   pattern (the ALB is created by the controller, so its alias is added on a second apply) applies to the standby too.
4. **Argo CD**: register the standby cluster with the hub and label it. The ApplicationSets already select clusters by label.

## Cost

Roughly doubles the fixed costs of the stack: a second Aurora instance (the secondary needs at least one), a second set of NAT gateways and an EKS control plane
($73/month each), a minimum node group, plus cross-region data transfer for replication. Plan on +60-80% of the single-region bill for a warm standby. A *pilot light*
(no EKS in the standby until needed, the database and bucket still replicating, infrastructure created by Terraform during the incident) is much cheaper and has an RTO of hours.

## Before building it

1. Run **one** region in production for long enough to know its real traffic, its real failure modes, and that Terraform and Argo CD apply cleanly.
2. Decide the RPO/RTO the business needs; if it is "an hour, some loss is fine", [backup and restore](../runbooks/backup-and-restore.md) into another region (cross-region
   snapshot copy) is a fraction of the cost and complexity. That row is currently *not configured* there; adding it is the first, cheap step.
3. Build the standby in a **non-production** environment first and run the drill below there.

## The drill (do this before trusting any of it)

1. Create the standby in `staging`. Load data; confirm replication lag (`AuroraGlobalDBReplicationLag`) is stable.
2. Planned switchover to the standby: measure the time to serve writes. Switch back.
3. Unplanned failover with `--allow-data-loss` after breaking the primary's health check; measure RPO (rows missing) and RTO (to a green health check and a successful sign-in, task create and attachment download).
4. Write down what surprised you, fix it, and repeat quarterly.
