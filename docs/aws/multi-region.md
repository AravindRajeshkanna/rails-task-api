# Multi-region: built, checked offline, never applied

**Status: the Terraform and GitOps for an active/passive pair exist and pass every check that needs no AWS account. Nothing has been applied, and neither has the
single-region platform it extends.** The checks are `terraform validate`, `terraform fmt`, and `terraform test`, which plans and applies the whole configuration
against *mocked* AWS providers for each role and asserts what each creates (the tests are mutation-checked: breaking the wiring makes them fail). They prove the conditional logic, not that AWS accepts it. In
the first hour they also found two defects in the existing single-region code that a real `terraform plan` would have hit (a security-group description with an apostrophe, which the AWS provider rejects,
and certificate-validation records keyed by values unknown at plan time; both fixed). Expect more on the first real apply. [ADR 45](../decisions.md) has the reasoning; [the failover runbook](../runbooks/regional-failover.md) is the procedure.

## What it is

**Active/passive, warm standby.** One region serves all traffic. A second holds a continuously replicated copy of the data and a scaled-down copy of the
platform, and takes over when Route 53's health check on the primary fails for about a minute and a half (DNS fails over by itself; **promoting the database and scaling the standby up are deliberate, human steps**: [runbook](../runbooks/regional-failover.md)).
Active/active is not proposed: it needs conflict-free writes, and every write path here (tasks, memberships, sessions, the outbox) assumes one database.

| Goal | Value to aim for | Honest range |
|---|---|---|
| **RPO** (data lost) | seconds | Aurora Global Database replication lag is typically under a second, but an *unplanned* failover accepts whatever had not replicated. Zero is not available |
| **RTO** (time to serve again) | 15-30 minutes | Dominated by promoting the database (a few minutes), scaling the standby up (Karpenter needs nodes), and people deciding. Automated, rehearsed failover can approach 5-10 minutes; unrehearsed, plan on an hour |

These are targets to verify in a drill, not measurements.

## Component by component

| Component | In the second region | How | What is lost or different |
|---|---|---|---|
| **DNS** | One name, two answers | Route 53 *failover* records for `api.<domain>` (alias records, so TTLs are the load balancers'); the health check calls the primary load balancer's `/up` directly, every 30 s, three failures to trip | Resolvers that cache longer take longer to move; a health check that passes while the app is broken in a way `/up` does not see will not fail over |
| **Network, EKS, Karpenter, Argo CD** | The same Terraform root module applied again with its own state and `region` | `envs/prod-dr.tfvars` + `envs/prod-dr.backend.hcl`; the standby cluster is registered with Argo CD labelled `env=prod-dr`, which the existing ApplicationSets select ([ADR 26](../decisions.md)) | Standby runs at minimum scale (API 1, worker min, no canary); scale-up is part of failover (`SIZE_AS=prod` re-render) |
| **Database** | Aurora **Global Database**: a read-only secondary cluster in region B | `aws_rds_global_cluster` wrapping the primary; the secondary cluster joins it (`global_cluster_identifier`, no master credentials). Every database on the cluster replicates: primary, Solid Queue, Solid Cache, Solid Cable, `auth`, `notifications` | Replication is asynchronous (RPO above). The standby is read-only until promoted. The standby has no RDS-managed master secret (it replicates the primary's users and the per-service passwords already in Secrets Manager) |
| **Object storage** (attachments, avatars) | A replica bucket | S3 Cross-Region Replication (versioning is already on); each region's app reads its own bucket from `AWS_S3_BUCKET` | Objects written seconds before the failure may be missing; CRR is eventually consistent (S3 Replication Time Control narrows it to 15 minutes, with an SLA) |
| **Container images** | Same images | ECR registry replication rule to region B | New images take a moment to appear there; deploy to the standby from the replicated tag |
| **Secrets** | Replicas | Secrets Manager multi-Region secrets (`replica` blocks), including the JWKS signing key, so tokens issued before the failover still verify | Replicas are read-only until promoted; rotating in the primary replicates |
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

## What was built, and where

One root module, applied twice: once per region, each with its own state. `dr_role` says how a stack was built (`none`, `primary`, `secondary`); it does **not** say which
side is serving after a failover, and no Terraform change is needed for the failover itself.

| What | Where | Primary (`dr_role = primary`) | Standby (`dr_role = secondary`) |
| --- | --- | --- | --- |
| Names | `locals.tf` | unchanged | everything gets `-dr` (`task-api-prod-dr`), so the account-global names (IAM roles, the SES user) cannot collide |
| Database | `database.tf` | `aws_rds_global_cluster` wrapping the existing cluster | the same module as a secondary member: no master user, its own KMS key, `source_region`, the primary's engine version (`db_engine_version`) |
| Object storage | `storage.tf` | S3 replication to the standby's bucket (Replication Time Control by default) | the same, back to the primary's bucket, so after a failover new uploads flow home and failback is a switchover |
| Images | `ecr.tf` | an ECR replication rule for `task-api/*` | a repository creation template, so replicated repositories get immutable tags and the same lifecycle |
| Secrets | `secrets.tf` | every secret gets a `replica` in the standby's region | creates none (and no signing key, no SES user): it reads the replicas under the same names |
| DNS | `edge.tf` | the name becomes a Route 53 failover pair with a health check on the primary load balancer's `/up`, and an alarm | never owns the name or the certificate's validation record (it has a certificate of its own, issued by waiting) |
| CI/CD | `github.tf` | the deploy role | none: CI pushes only to the primary's registry |
| GitOps | `deploy/gitops/envs/prod-dr/`, `render_gitops.rb`, the prod ApplicationSet | | an environment `prod-dr` at standby size (one replica, no canary), same hostname, the primary's secret paths; `SIZE_AS=prod` renders it at production size |
| Promotion | `.github/workflows/promote.yml` | | `prod` can be promoted into `prod-dr` (a pull request, then a human Sync) |
| Tests | `deploy/terraform/tests/multi_region.tftest.hcl`, CI | | run on every pull request |

Variables: `dr_role`, `peer_region`, `peer_ready` (the other stack exists: turns on S3 replication and the DNS failover), `db_engine_version`, `dr_s3_replication_time_control`.
Files to copy and edit: `envs/prod-dr.tfvars` and `envs/prod-dr.backend.hcl` (the standby's state is kept in a bucket **in the standby's region**: state held only in the failed region cannot be used to operate the standby).

## Building it (in this order)

Every step is unrun. Do it in `staging` first: copy the two `prod-dr.*` files to `staging-dr.*` and use `environment = "staging"`.

1. **Prerequisites in the standby region**: Bedrock model access, SES verified identity and production access, service quotas (Spot vCPUs, Elastic IPs), the state bucket for `prod-dr` ([setup guide](setup-guide.md) steps 1-2, in that region).
2. **Primary, step 1**: set `dr_role = "primary"` and `peer_region` in `prod.tfvars`; `terraform apply`. It joins the database to a global cluster (no interruption), puts replicas of every secret in the standby region, and starts replicating images. `terraform output database_engine_version`; keep it.
3. **Standby**: put that version in `envs/prod-dr.tfvars` (`db_engine_version`), fill the `REPLACE_*` values, then `terraform init -backend-config=envs/prod-dr.backend.hcl && terraform apply -var-file=envs/prod-dr.tfvars`. About 25 minutes (EKS, Aurora).
4. **Cluster**: follow the setup guide's cluster steps for the new cluster (`terraform output -json > tmp/prod-dr-outputs.json`, `ruby deploy/scripts/render_gitops.rb prod-dr tmp/prod-dr-outputs.json`, register the cluster in Argo CD with labels `taskapi/managed=true` and `env=prod-dr`, then sync). Promote the images: run *Promote* from `prod` to `prod-dr`, merge, Sync. Set `alb_exists = true` in `prod-dr.tfvars` once its load balancer appears, and apply.
5. **Primary, step 2**: set `peer_ready = true` (and `alb_exists = true` if not already); `terraform apply`. This starts S3 replication and replaces the single DNS record with the failover pair (a few seconds of DNS gap: pick a quiet moment, TTL is already low).
6. **Backfill**: replication only covers new objects. Copy the existing ones once with an S3 Batch Replication job, and re-push the image tags a deployment needs that predate the ECR rule.
7. **Check replication**: `AuroraGlobalDBReplicationLag`, S3 replication metrics, a test upload visible in the other bucket, the standby's `/up`, a login against the standby's load balancer directly. Then **run the drill below**.

## What Terraform does not do

- **Fail over.** DNS does, by health check. The database promotion, scaling the standby, and promoting its secrets are runbook steps on purpose: a wrong automatic database failover loses data.
- **Make the standby identical.** It runs at standby size and the images are whatever was last promoted into `prod-dr`; keep it current by promoting after each production release, or the standby will fail over to old code.
- **Replicate what is not data**: Argo CD's own state, Grafana dashboards, anything in the cluster that is not in Git.
- **Cover accounts.** Both regions are assumed to be in one account (the ECR rule, the replication roles, the ACM validation record all depend on it).

## Cost

Roughly doubles the fixed costs of the stack: a second Aurora instance (the secondary needs at least one), a second set of NAT gateways and an EKS control plane
($73/month each), a minimum node group, plus cross-region data transfer for replication. Plan on +60-80% of the single-region bill for a warm standby. A *pilot light*
(no EKS in the standby until needed, the database and bucket still replicating, infrastructure created by Terraform during the incident) is much cheaper and has an RTO of hours.

## Before applying it

1. Run **one** region in production for long enough to know its real traffic, its real failure modes, and that Terraform and Argo CD apply cleanly.
2. Decide the RPO/RTO the business needs; if it is "an hour, some loss is fine", [backup and restore](../runbooks/backup-and-restore.md) into another region (cross-region
   snapshot copy) is a fraction of the cost and complexity. That row is currently *not configured* there; adding it is the first, cheap step.
3. Apply it to a **non-production** environment first and run the drill below there. Expect surprises on the first apply.

## The drill (do this before trusting any of it)

1. Create the standby in `staging`. Load data; confirm replication lag (`AuroraGlobalDBReplicationLag`) is stable.
2. Planned switchover to the standby: measure the time to serve writes. Switch back.
3. Unplanned failover with `--allow-data-loss` after breaking the primary's health check; measure RPO (rows missing) and RTO (to a green health check and a successful sign-in, task create and attachment download).
4. Write down what surprised you, fix it, and repeat quarterly.
