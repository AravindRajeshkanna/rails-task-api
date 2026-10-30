# Capacity planning

How much to run for how much load, and what to watch so that the answer stays true. The numbers come from [performance.md](performance.md); the arithmetic is `loadtest/capacity.rb`.

```sh
ruby loadtest/capacity.rb --peak-rps 900            # pods, pods to survive losing a zone, database connections against the limit
```

## The model, in four lines

1. **The unit of scaling is a pod.** One Puma process with 5 threads carries about 260 requests/s with a p95 of 30 ms and saturates at about 340 ([measured](performance.md#capacity-of-one-puma-process-5-threads)). Past that, latency is queueing, and the load shedder starts refusing the expensive reads ([ADR 62](decisions.md)).
2. **Run pods at 70% of the knee at peak** (182 requests/s each): the rest is for a burst, a deploy that takes a pod out, and the autoscaler's lag (the HPA targets 70% CPU; check that this keeps a pod under the knee on real traffic).
3. **Size for losing a zone**: with pods spread over three zones, losing one leaves two thirds of the fleet to carry the peak at up to 90% of the knee. For 900 requests/s that is 5 pods in normal times and 6 provisioned.
4. **Every thread of every pod is a database connection.** API pods contribute `RAILS_MAX_THREADS` each, workers contribute their pools' threads (7 per process with the current `config/queue.yml`), and a reserve covers migrations, consoles, monitoring and the cache/queue/cable pools. Aurora's limit is `LEAST(memory / 9,531,392, 5,000)`, and an ACU is 2 GiB, so a ceiling of 8 ACU allows about 1,800 connections and 64 ACU is capped at 5,000.
   The connection limit, not CPU, is the first wall for a large fleet: 5,000 requests/s needs about 33 pods and 200 connections, which is far from the limit, but a fleet that grows threads (`RAILS_MAX_THREADS=20`) or pods without a pooler (RDS Proxy, PgBouncer) can reach it.

## What to watch (all are metrics already)

| Question | Signal | Act when |
| --- | --- | --- |
| Are pods near the knee? | `taskapi_puma_busy_threads` / threads, `taskapi_puma_backlog`; request rate per pod | busy threads above ~70% of threads at peak, or any backlog: raise the HPA ceiling or lower its target |
| Is the database the limit? | Aurora ACU utilisation, `taskapi_db_pool_connections{state="waiting"}`, connections against the limit above | ACU at its ceiling at peak (`db_max_acu`), or pool wait above zero: add readers and use the replica ([ADR 60](decisions.md)), then a larger ceiling |
| Is the queue keeping up? | `taskapi_queue_oldest_ready_job_age_seconds`, `taskapi_queue_ready_jobs` per queue | oldest job older than a minute in `critical`/`mailers`: more worker processes (`JOB_CONCURRENCY`); KEDA scales the worker Deployment on backlog |
| Are we shedding? | `taskapi_load_shed_total`, `TaskApiLoadShedding` | any sustained rate: this is the capacity alert |
| Is one tenant the load? | `taskapi_organization_budget_exceeded_total`, the logs by `organization_id` | one organization repeatedly at its budget: talk to it before raising the budget |
| Is the budget being spent? | the SLO burn alerts ([slo.md](slo.md)) | tickets are the early warning: capacity work belongs in the next sprint, not after a page |

## What the model does not know

It does not know your traffic mix: the measured ceiling is for a read-heavy mix of lists, searches and a few writes, and a workload of mostly analytics or search has a lower one (search is 5x the cost of a list). It does not model the database's own growth (indexes and tables get slower to write as they grow; [the index costs](performance.md#what-the-indexes-cost-measured) were measured at 150,000 tasks). It does not cover cost (`monthly_budget_usd` and the Budgets alert do).
Redo the measurement, not the arithmetic, when the shape of the load changes: `loadtest/ci.sh` runs nightly and is the way to find out.
