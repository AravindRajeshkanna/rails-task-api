# Performance

What was measured, how, what changed because of it, and how to measure again. Numbers are from one laptop
and are for comparing a change with the one before it, **not** capacity planning for EKS.

## How it was measured

| | |
| --- | --- |
| Machine | Apple M1, 8 cores, 8 GB RAM, macOS 27 |
| App | Rails 8.1.4, Ruby 4.0.9, **production mode** (eager loading, JSON logs at `warn`), one Puma process with 5 threads |
| Database | PostgreSQL 17 on the same machine, 149,000 tasks in 100 projects, one "whale" project with 50,000 tasks |
| Load | k6 2.3.0 on the same machine, so it competes for the same CPU: results are slightly pessimistic |
| Not on | Rack::Attack (`RACK_ATTACK_ENABLED=false`), Solid Queue workers, AI (off, as in production by default) |

Data and scenario are reproducible: [loadtest/README.md](../loadtest/README.md).

## Capacity of one Puma process (5 threads)

Open-model arrival rates, 40 seconds each after a warm-up; each visit is about 7 requests.

| Visits/s | Requests/s | Failed | Dropped visits | p50 | p95 | p99 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10 | 66 | 0% | 0 | 5 ms | 30 ms | 61 ms |
| 20 | 130 | 0% | 0 | 5 ms | 29 ms | 62 ms |
| 40 | 263 | 0% | 0 | 7 ms | 30 ms | 68 ms |
| 80 | 338 | 0% | 895 | 1,233 ms | 1,391 ms | 1,416 ms |

**Reading it:** one process carries about 260 requests/s with a p95 of 30 ms and no errors, and saturates
somewhere between 40 and 80 visits/s (~340 requests/s is the ceiling). At 80 the latency is queueing, not slow
queries: every endpoint slows by the same ~1.4 s. So the unit of scaling is the pod. The API's HPA targets 70% CPU
(`autoscaling.targetCPUUtilizationPercentage` in the chart); whether that keeps a pod safely below the ceiling above
depends on its CPU request, so check it against real traffic rather than assuming it.

p95 by endpoint, in milliseconds:

| Endpoint | 10/s | 20/s | 40/s |
| --- | ---: | ---: | ---: |
| `GET /projects` | 8 | 6 | 15 |
| `GET /projects/:id/tasks` (default) | 13 | 11 | 20 |
| `GET /projects/:id/tasks` (the 50k-task project) | 25 | 16 | 24 |
| `GET /projects/:id/tasks?status&sort` | 40 | 31 | 34 |
| `GET /projects/:id/tasks?q=` (text search) | 63 | 63 | 69 |
| `GET /tasks/:id` | 6 | 8 | 18 |
| `GET /projects/:id/analytics` | 10 | 53 | 47 |
| `GET /activity` | 5 | 7 | 17 |
| `POST /projects/:id/tasks` | 17 | 11 | 21 |
| `PATCH /tasks/:id` | 16 | 12 | 25 |
| `POST /tasks/:id/comments` | 22 | 10 | 20 |

The slowest read is text search (`ILIKE '%term%'` on title and description, no usable index for the
description): fine today, and the first thing to move to a `tsvector` index if projects grow ([roadmap](roadmap.md)).
Analytics is cached for five minutes per project version, so its p95 is dominated by the occasional cache miss.

## What the measurements changed

Every query on the hot paths was run with `EXPLAIN (ANALYZE)` on this data set:

| Query | At ~1,000 tasks/project | Largest project (50,000 tasks) |
| --- | ---: | ---: |
| Default task list (newest first) | 0.25 ms | **10.0 ms** → 0.05 ms with the new index |
| Filter by status, sort by priority | 0.20 ms | 6.6 ms |
| Overdue tasks | 0.02 ms | 0.1 ms |
| `assignee=me` | 0.04 ms | 0.1 ms |
| Text search | 0.05 ms | 27 ms |
| Projects of a user | 0.03 ms | n/a |
| Due-soon reminder job (all projects) | 1.6 ms | n/a |

Almost everything was already index-served. The default listing is the one that was not: for a big
project PostgreSQL scanned and sorted every task of the project to return 25. The fix is a partial
composite index that matches the query's `ORDER BY` and skips deleted rows
(`index_tasks_on_project_id_and_created_at_when_kept`, migration `AddActiveTasksListingIndex`), built
concurrently. Under load, with the same traffic:

| Whale-project task list | Without the index | With it |
| --- | ---: | ---: |
| p95 | 57 ms | **24 ms** |
| average | 37 ms | **15 ms** |
| p95 of all requests at 40 visits/s | 48 ms | **30 ms** |

The database got ~200x faster for that query; the request got ~2.3x faster, because serialization
and the rest of the request do not shrink. That ratio is the honest number.

No other index was added: the planner already used the existing ones, and an index that no measured
query needs only slows writes. Add one when `EXPLAIN` on production-sized data shows a scan, not before.

## Other performance guards that run in CI

- **Bullet** raises on N+1 queries and on unused eager loading in every request spec.
- New endpoints assert their query count (`count_queries` in `spec/support/query_helpers.rb`), so a loop
  that issues a query per row fails the build.
- Offset pagination at depth: page 400 of the whale project (offset 10,000) is 3.5 ms with the index. Past
  roughly a million rows in one project, switch that endpoint to keyset pagination.

## Known limits of these numbers

- One run per configuration; there is run-to-run variance of several milliseconds at p95.
- Client and server share the machine and the CPU.
- A laptop SSD and local socket, not Aurora over a network: expect database round trips to cost more in EKS.
  The shape (what scales with data, what is flat) should carry over; the absolute numbers will not.
- The write path here does not include Solid Queue workers or webhook delivery.
