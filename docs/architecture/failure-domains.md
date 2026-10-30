# Failure domains, blast radius, and how to find out by breaking things

A **failure domain** is a set of things that fail together. **Blast radius** is how much of the product a failure takes with it. This page lists the domains, says what each failure does to users and what keeps working, is honest about what has and has not been tried, and ends with a plan for trying: a game day. Resilience mechanisms themselves are in [resilience.md](resilience.md); the regional case is [regional-failover.md](../runbooks/regional-failover.md) and its [drill](../runbooks/failover-drill.md).

> **Nothing on this page has run on AWS.** The "Tried" column says what is covered by a test, a local measurement or nothing. A claim marked *by design* is what the configuration says should happen, not something observed.

## The domains, smallest first

| Failure | What users see | What keeps working | Detected by | Recovery | Tried |
| --- | --- | --- | --- | --- | --- |
| **A request** hits a bug or a slow dependency | An error or a timeout on that request | Everything else | Error ratio, [SLO burn-rate alerts](../slo.md) | Fix and deploy | Specs |
| **A pod** dies or is unready | Nothing, if others are ready: the load balancer stops sending to it; in-flight requests on it fail | Other replicas (`minAvailable: 1`, rolling updates with `maxUnavailable: 0`) | Readiness probe; replica count | Kubernetes replaces it | `/readyz` and `/livez` specs; the FIS pod-delete experiment exists, **never run** |
| **A node** is lost (or a Spot reclaim) | As a pod, for every pod on it | Replicas spread across zones (`topologySpread`) | Node and pod alerts | Karpenter provisions a node | FIS node-terminate exists, **never run** |
| **A zone** is lost | A short disturbance while pods move; capacity drops by a third | Replicas in other zones. [capacity-planning.md](../capacity-planning.md) sizes the fleet so that losing a zone still carries the peak at 90% | Load-balancer target health, latency | Autoscaling, Karpenter | **Not tried.** Prod runs a NAT gateway per zone and two database instances *by design* |
| **The Aurora writer** fails | Writes fail until a reader is promoted and the apps reconnect. Reads that go to the reader keep working. **Also jobs, cache and Action Cable**: they live in databases on the same cluster | The read-only mode can be switched on to answer `503 read_only` instead of `500` | Readiness, `taskapi_db_pool_connections`, error ratio | Aurora promotes a reader | **Not tried; the write outage and whether pods reconnect without a restart are unmeasured** |
| **The read replica** fails | Nothing: reads fall back to the writer and a circuit breaker stops trying the replica ([ADR 60](../decisions.md)) | Everything | Replica fallback events in the log | Aurora replaces it | Specs; verified against a local replica, not Aurora |
| **A dependency** fails: the model provider, the AI service | The AI endpoints answer `503 ai_unavailable` with `Retry-After`, then fail fast while the breaker is open | Everything else ([ADR 58](../decisions.md)) | `TaskApiAiErrors`, `TaskApiCircuitOpen` | Provider recovers; the breaker probes | Specs, including the breaker's states |
| **The Auth service** is down | New sign-ins and refreshes fail. Tokens already issued still verify (public keys are cached 10 minutes and served stale for up to 24 hours) | Everyone already signed in | Auth readiness; sign-in errors | Restart | JWKS stale-if-error specs; no live exercise |
| **SNS or SQS** is unreachable | Nothing at first; assignment emails are late | The API, the inbox, webhooks. Events wait in the outbox | `TaskApiEventOutboxStuck` (oldest unpublished event over 5 minutes) | The relay drains it when AWS returns | Specs; [runbook](../runbooks/event-outbox.md) |
| **SES or Slack** fails | Emails and Slack messages are late or dropped after retries | Everything else | Dead-letter queue depth | Redrive from the queue | Consumer specs |
| **Secrets Manager or External Secrets** is down | Nothing for running pods (the Kubernetes Secret persists). A pod that starts needs the Secret to exist | Running workloads | External Secrets sync status | Wait; no manual step | By design |
| **The registry** (ECR) is down | Nothing running. A new node or pod cannot pull an image it has not cached, so scaling out stalls | Running pods | Image-pull errors | Wait | By design |
| **Git or Argo CD** is down | Nothing running. No deploys, no rollbacks through Git | Everything running | Argo CD health | Restore Argo CD; `kubectl` can still roll a Deployment back by hand | By design |
| **A bad deploy** | A fraction of traffic, for the length of the canary analysis, then an automatic rollback | The stable version keeps its share | The canary's analysis; error ratio | Argo Rollouts aborts | Rollout analysis defined, **never run** |
| **A bad migration** | The risk is a lock or a rewrite on a hot table | Reads and writes that do not touch it | Lock waits, latency | `strong_migrations` blocks the dangerous forms before they merge ([runbook](../runbooks/zero-downtime-migrations.md)) | CI |
| **A region** is lost | The API is down until the standby takes over: 15 to 30 minutes by design, with seconds of writes lost | Nothing in the lost region | Route 53 health check on `/readyz` | The [failover runbook](../runbooks/regional-failover.md) | **Never applied.** The probe was run locally against a server in read-only mode |
| **A tenant** misbehaves | That tenant gets `429` and, for the expensive reads, `503 overloaded`; others are not slowed beyond the shared database | Other tenants | `organization_budget.exceeded` events | The budget resets in 5 minutes | Request specs; one load run |

## Shared fate: where the lines on the diagram are not real

- **One Aurora cluster holds every database.** The API's data, the Solid Queue, Solid Cache and Solid Cable databases, the Auth service's and the Notification service's all live on it, under separate roles. Their separation is logical. A cluster failure, a failover, a storage problem, or one service saturating the writer's CPU or its connection limit ([capacity-planning.md](../capacity-planning.md)) takes the **API, the job queue, the cache and sign-in** with it at once. That is the largest blast radius in the system and it is a deliberate economy; the list below says what to do about it first.
- **Jobs and the cache live in the database they protect.** When the database is slow, job workers, rate limiting and caches compete for the same capacity as requests.
- **One region.** The standby is a plan.
- **One load balancer and one WAF** in front of everything in the region.
- **One signing key** for every token in Auth mode, and one shared token between the API and the AI service ([threat-model.md](../threat-model.md)).

## What would shrink the biggest blast radius

In order of cost, and none is a commitment:

1. **Know the writer failover time and what the apps do during it.** It is the one number everything else assumes. Experiment E7 below measures it.
2. **Give the queue and cache their own cluster or instance class** (or move them off PostgreSQL), so a job storm cannot starve requests and a cache outage does not take jobs.
3. **A separate Aurora cluster for the Auth service.** Sign-in then survives an API database incident, and the reverse.
4. **A pooler** in front of the writer, so a pod stampede after a failover cannot exhaust connections.
5. **Cells**: independent full copies of the stack, each serving a set of organizations. Only worth it when one tenant's incident must not reach another's, and it needs the ownership map to be real ([data-lifecycle.md](data-lifecycle.md)).

## Blast radius of a change

A deploy is the most common failure. Prod rolls out as a canary with automatic rollback (staging also; dev replaces in place). Migrations are reviewed by `strong_migrations`. A configuration or secret change takes effect at the next pod start, so it is applied by rolling restart, one replica at a time, and a bad value stalls the rollout on the readiness probe instead of reaching users. Terraform changes have no canary: a plan is the review, and the multi-region roles are tested offline with mocked providers (`terraform test`).

## Game day

Thinking about failure finds the second-order problems; breaking things finds the rest. A game day is a scheduled hour in **staging** in which a few people break one thing on purpose, with the dashboards open, and write down what happened. It is the habit that turns "by design" into "observed".

### Rules

1. **State the steady state first**, as numbers from [slo.md](../slo.md): error ratio, p95 latency, queue age, outbox age. If it is not steady before you start, do not start.
2. **Write the hypothesis before the experiment**, in the form "when X fails, Y happens and Z does not". A hypothesis that cannot be wrong teaches nothing.
3. **Limit the blast radius and name the abort condition.** One thing at a time; staging first; an alarm as a stop condition (the FIS templates stop on the 5% error alarm); a person whose only job is to stop it.
4. **Announce it**, and do not run it when something else is changing.
5. **Every surprise becomes a change**: a fixed runbook, a new alert, a test, or an item on a list with a date. A game day with no changes afterwards did not happen.
6. **Repeat**, quarterly and after anything that changes the topology. Rotate who drives.

### Experiments

Ordered from cheapest to most dangerous. Each assumes load from `loadtest/k6/api.js` at a moderate arrival rate.

| # | Do | Hypothesis | Watch | Abort if |
| --- | --- | --- | --- | --- |
| E1 | Start the FIS **pod-delete** experiment | No user-visible errors beyond the requests on that pod; a replacement is ready within a minute | Error ratio, replica count, p95 | Error ratio over 5% (FIS stops itself) |
| E2 | Start the FIS **node-terminate** experiment | Pods on it are replaced elsewhere; spread across zones keeps at least one ready; brief latency rise | Same, plus node count | Same |
| E3 | Scale the AI service to zero | Only the AI endpoints fail (`503 ai_unavailable`, then fail-fast); the breaker opens; the SLOs for everything else hold; recovery is automatic | `TaskApiCircuitOpen`, AI error rate, non-AI error ratio | Any non-AI endpoint above 1% errors |
| E4 | Scale the Auth service to zero | Existing tokens keep working; sign-in fails with a clean error; API errors do not rise; recovery needs no API restart | Sign-in error rate, 401 rate on the API | API 5xx rises |
| E5 | Deny the workload's SQS/SNS permissions | The API is unaffected; the outbox grows; `TaskApiEventOutboxStuck` fires within about 6 minutes; restoring access drains it with no lost event | Outbox oldest age, the alert, then queue depth | The outbox cannot drain after restoring |
| E6 | Reboot the Aurora **reader** | Reads fall back to the writer; the breaker opens and later closes; no errors a user sees | Replica breaker, p95, writer CPU | Writer CPU saturates |
| E7 | **Fail over the Aurora writer** (a reboot with failover) | *Unknown.* The hypothesis to test: writes fail for no more than a minute, then resume without restarting any pod; reads never fail; jobs resume. Record the actual write outage, every error code seen, whether pods needed restarting, and how long jobs and cache took to recover | Error ratio by status, `taskapi_db_pool_connections`, readiness, queue age | Writes still failing after five minutes: restore by restarting the pods, and write that down |
| E8 | Revoke External Secrets' access to Secrets Manager, then restart one pod | Running pods are unaffected; the restarted pod starts from the Kubernetes Secret that already exists | Sync status, pod start | The pod cannot start |
| E9 | Run the load test at twice the measured capacity | Load shedding engages: expensive reads answer `503 overloaded`; cheap reads and all writes keep being served; the error budget burns visibly but bounded ([ADR 62](../decisions.md)) | Shed-request metric, SLO burn alerts, per-endpoint latency | Writes failing |
| E10 | The regional [failover drill](../runbooks/failover-drill.md), planned then unplanned | Its own targets: no acknowledged write lost in the planned case; full service in 15 to 30 minutes in the unplanned | The drill's report | Its own |

E7 is the most valuable and the one to do first in staging: every other claim about the database depends on it.

### The record

For each experiment: the date and who drove; the steady state before; the hypothesis; the time of injection and of each visible effect; what was observed against what was predicted; every error code seen; time to recover and whether a human had to act; what surprised you; what changes (an owner and a date for each). Keep the records in the repository next to the runbooks, so the next game day starts from the last one.
