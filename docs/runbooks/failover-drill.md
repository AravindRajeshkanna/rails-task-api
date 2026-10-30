# Runbook: the failover drill

> **Never run.** The staging pair exists as configuration (`envs/staging-dr.*`, the `staging-dr` GitOps environment, [multi-region](../aws/multi-region.md)) and has not been applied, so every AWS step here is unrun and the targets are
> assumptions, not measurements. The one tool this page depends on, `deploy/scripts/drill_probe.rb`, **has** been run: against a local server restarted into read-only mode and back, it reported the connection errors, the `503 read_only` answers, the time to
> full service and the count of acknowledged writes lost, and `spec/scripts/drill_probe_spec.rb` covers its arithmetic.

A failover you have not rehearsed is a hope ([regional failover](regional-failover.md) says the same about itself). The drill produces three numbers and a list: **RPO** (acknowledged writes lost), **RTO** (how long a user could not use the service), whether **read-only mode** did its job (writes
refused with `503 read_only`, never a 500; reads working), and **what surprised you**. Do it in staging, with two people (one drives, one keeps the timeline), and not on a day anything else is changing.

## Before you start

1. The staging pair is applied in the order of [multi-region, "Building it"](../aws/multi-region.md#building-it-in-this-order), using `envs/staging.tfvars` (the opt-in lines) and `envs/staging-dr.tfvars`; the standby's cluster is registered in Argo CD with `env=staging-dr`.
2. Load real-ish data: `bin/rails db:seed` or a restore of a recent dump (`deploy/scripts/db_restore_check.sh` shows how), so replication has something to do. Check `AuroraGlobalDBReplicationLag` has been stable (seconds) for an hour.
3. A **throwaway project** and a token for it. The probe creates one task a second in it; nothing else is touched.
   ```sh
   export PROBE_TOKEN=<bearer token>      # from POST /api/v1/session
   ruby deploy/scripts/drill_probe.rb https://api.staging.<domain> <project id> 3600      # leave it running for the whole drill; Ctrl-C prints the report
   ```
   Run it from **outside** AWS (your laptop, or a different region): a probe inside the failing region measures nothing useful. It prints a report when it ends: reads and writes unavailable, the answers it got, the time to full service, and the acknowledged tasks that are gone.
4. Open the dashboards you will use during a real one: `AuroraGlobalDBReplicationLag`, the Route 53 health check, `taskapi_read_only_refusals_total`, the standby's `/up`.
5. Write down the start time and the targets you are checking against (below).

| | Target | Where it comes from |
| --- | --- | --- |
| RPO, unplanned | seconds of writes; the count is the probe's "acknowledged writes lost" | Aurora Global Database replication lag |
| RPO, planned | **zero** | switchover waits for the secondary to catch up |
| RTO, unplanned | 15-30 minutes to full service | [multi-region](../aws/multi-region.md#what-it-is); a first drill will probably be slower |
| RTO, planned | write outage under 5 minutes | drain, switchover, scale, DNS |
| Read-only mode | no 500s from the API during the window; reads keep working | [ADR 46](../decisions.md) |

## Drill 1: planned switchover (no data loss expected)

Follow "Planned switchover" in [regional failover](regional-failover.md#planned-switchover-no-data-loss-for-drills-and-planned-maintenance) exactly as written, step 0 included (drain writes with `READ_ONLY=true`). Note the time of each step.

**Expect:** the probe shows reads working throughout, writes refused (`503`) from the drain until the new writer takes traffic, and **zero** acknowledged writes lost. A single lost write is a finding, whatever else happens.
**Then** switch back the same way and note whether failback was as boring as it should be.

## Drill 2: unplanned failover (with data loss, on purpose)

Only after drill 1 went well. Follow "Unplanned failover" in the same runbook, with the break done the way the real event would do it: invert the primary's health check or block its load balancer's security group, not a polite scale-down.

**Expect:** the probe shows DNS moving (connection errors, then answers from the standby), writes refused with `503 read_only` until the database is promoted (the window the planned order avoids), then recovering. The report's "acknowledged writes lost" is your measured RPO; compare it with the replication
lag just before the break. "Time to full service" is your RTO; the timeline tells you where it went (deciding, promoting, scaling, DNS).

## Record it

Copy this into the incident-style write-up (or the pull request that fixes what you found):

| | Drill 1 (planned) | Drill 2 (unplanned) |
| --- | --- | --- |
| Date, who drove, who kept time | | |
| Replication lag before | | |
| Break / drain started | | |
| Health check tripped / drained | | |
| Database promoted (or switched over) | | |
| Standby at production size | | |
| First tick where reads **and** writes worked | | |
| **Time to full service** (probe) | | |
| **Acknowledged writes lost** (probe) | | |
| 500s seen (should be none; `503 read_only` is expected) | | |
| What surprised you | | |
| What the runbook got wrong | | |

## After

1. Fail back, and put the pair in its resting state (standby at standby size, `READ_ONLY` back on).
2. Fix what the drill found, **in the runbook and in the code**, before anything else: every step you improvised is a step the next person will not know.
3. Decide, with the numbers, whether the targets are right and whether [the cheaper option](backup-and-restore.md#a-copy-in-another-region) would have been enough.
4. Repeat quarterly, and after any change to the Terraform, the database version or the ingress. If you do not keep the staging standby (it costs an Aurora instance, NAT gateways and a control plane), destroy it and rebuild it for the next drill: that is itself a rehearsal of
   the build.

## What this does not exercise

The drill covers the data path and the API. It does not exercise a regional outage of **Argo CD or Git** (the runbook's "things it cannot fix"), the **Notification service's** queue and email (check it by hand: assign a task and see the email), **Bedrock and SES** in the other region
(model access and verified identities are per region), or **workers** on a read-only database (they log errors until promotion). Add them to the checklist when you find out you need them.
