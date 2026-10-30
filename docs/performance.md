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

The slowest read is substring text search (`ILIKE '%term%'` on title and description, no usable index for the
description); full-text search ([below](#full-text-search)) is the indexed alternative.
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

## Full-text search

`GET /search` and `?search=` use a stored `tsvector` (title weight A, description weight B) with a GIN index
([ADR 38](decisions.md)). Measured in-process (no HTTP, no k6) against the 149,000-task database, 50,000 of them in one project,
`EXPLAIN (ANALYZE)` plans in the PR:

| Query (first page of 25) | Substring `?q=` (`ILIKE`) | Full-text `?search=` / `GET /search` |
| --- | ---: | ---: |
| **Rare** word (15 of 50,000 tasks) | 62 ms | **2 ms** |
| **Common** word (29,000 of 50,000 match) | 1.7 ms | 21 ms |
| Two common words, or a phrase | n/a (one substring) | 13-23 ms |
| Word that matches nothing | scans the project | 1 ms |
| The count behind the pagination header | n/a | 1 ms (rare), 11-19 ms (common) |

Two different shapes, and neither wins everywhere. A substring search walks the newest tasks first and stops after 25 hits, so a *common*
word is nearly free and a *rare* word reads the whole project (no index can serve `%word%` on the description). A ranked search has to
score **every** match before it knows the best 25, so its cost grows with the number of matches: tiny for a rare word, about 20 ms for a word
in 60% of 50,000 tasks. The seed data (26 words) is the worst case for that; real text is mostly rare words. Highlights cost nothing extra,
because PostgreSQL only computes them for the 25 rows it returns.

**Capping the ranking was measured, and not built.** The idea was to rank only the most recent N matches of a broad query. Tried with N = 1,000, on the same data:

| Common word (59% of tasks match) | Ranked over every match (shipped) | Ranked over the newest 1,000 matches |
| --- | ---: | ---: |
| In the 50,000-task project: first page | 21.0 ms | **2.4 ms** |
| In the 50,000-task project: the count | 11.3 ms | 1.5 ms |
| Across all 57,000 visible tasks: first page | 22.1 ms | 23.0 ms |
| Across all 57,000 visible tasks: the count | 17.5 ms | 19.5 ms |
| A rare word, either scope | 1.3-2.0 ms | the same |

It works where a project's `(project_id, created_at)` index lets PostgreSQL walk newest first and stop, and does nothing across projects, which is the slow shape
(the nightly load test's p95 of 195 ms): there PostgreSQL scans `tasks` for the matches (11.5 ms of the 22) and the ranking is the small part, so a cap on ranking does not cap the work.
It would also change what a search returns (the best of the newest 1,000, not the best of all), to save 19 ms on a 50,000-task project and nothing on the query that matters. Nothing
is slow yet: p95 195 ms against a 600 ms limit, on a shared runner, with seed data built so that every "common" word matches 59% of rows, which real text does not. If cross-project search
becomes the slow one, the lever is not this: it is requiring a project (or a short list of them) for a broad query, or an index that can answer "newest matches first" across projects.

On a GitHub-hosted runner (the nightly load test, 10 visits a second, the same 149,000 tasks, k6, the app and PostgreSQL sharing the machine) the numbers are
a different order but the same shape, and cross-project search is the slowest endpoint, as predicted for words that match about half the rows: median 109 ms, p95 195 ms,
against p95 62 ms for the 50,000-task list, 94 ms for a project-scoped full-text search and 133 ms for substring search. All inside the thresholds (the search limit is 600 ms).

The migration that adds the column rewrites `tasks` under a lock: 3.7 s here ([runbook](runbooks/zero-downtime-migrations.md)). The GIN
index is 2.9 MB for 149,000 tasks and is built concurrently.

## Deep pages: offset against cursor

`?page=N` is `OFFSET`: the database walks and discards every row before the page, so a deep page costs more the deeper it is. On the
50,000-task project, newest first, first page of 25 after skipping N rows (`EXPLAIN (ANALYZE)`, execution time):

| Rows skipped | `page=` (offset) | `cursor=` (keyset) |
| ---: | ---: | ---: |
| 0 | 0.07 ms | 0.08 ms |
| 1,000 | 1.0 ms | 0.07 ms |
| 10,000 | 4.2 ms | 0.07 ms |
| 49,000 | **13.8 ms** | 0.08 ms |

The keyset query is `WHERE (created_at, id) < (cutoff)` on the same partial index, so it starts where the last page ended. Offset paging also
runs a `COUNT(*)` for the total, which keyset paging skips (that is why a cursor page has no total). Offset stays the default because
nothing is wrong with it at these sizes and a total is useful in a UI; the cursor is for feeds, exports and infinite scroll.

## Sparse fieldsets

`?fields=` lets a client ask for the few attributes a list needs. Measured on a page of 100 tasks from the 50,000-task project (in-process, 25 runs, median; the same query, the same preloads the default uses):

| `fields` | Bytes | Queries | Time |
| --- | ---: | ---: | ---: |
| everything (the default) | 54,521 | 5 | 16.0 ms |
| `id,title,status` | 7,289 (**-87%**) | 1 | **3.7 ms** |
| `id,title,status,assignee` | 10,853 | 2 | 5.1 ms |
| `id,title,status,tags,attachments` | 9,989 | 3 | 8.9 ms |

The saving is not just bytes: Alba evaluates a field's condition before it computes the value, and the controller preloads only the associations the fields need, so a list that shows a title and a status does not load the creator, the assignee, the tags and the attachments' blobs for 100 rows ([ADR 56](decisions.md)).

## The lists that only grow: audit logs and the activity feed

Audit events are appended on every change, so these lists have no ceiling, unlike a project's task list. Measured in PostgreSQL 17 with one busy project holding **1,000,000 events**
(a change every 16 seconds for three years), the project's audit log:

| | `page=` (offset) | `cursor=` (keyset) |
| --- | ---: | ---: |
| First page | 23.5 ms (22.8 of it is the `COUNT(*)` for the total) | 0.55 ms |
| After 100,000 events | 11.5 ms (+ the count) | 0.6 ms |
| After 500,000 events | 54 ms (+ the count) | 0.8 ms |
| After 990,000 events | 131 ms (+ the count) | 0.6 ms |

The organization's audit log has the same shape and index. These are fine at the sizes most projects reach (a project with 100,000 events pays 2 ms for its count), and they are opt-in: `cursor=` on both audit logs and on the feed, `page=` unchanged.

**The activity feed was the surprise.** `GET /activity` reads the events of *every project the caller is in*, and keyset paging alone did not help it: for someone in 8 projects holding
1.14 million events between them, the first page took **109 ms** by offset (plus 57 ms for the count) and **108 ms by a plain keyset query**, and 82 ms deep into it. PostgreSQL has no index that orders events across several
projects, so it reads all of their events and sorts them, whatever the page asks for. The cost was in the query's shape, not in the paging. `ActivityFeed` asks each project for its own newest 101 events, in index order,
and merges them (a lateral join over the caller's projects, `LIMIT 101` each: a page of at most 100 can never need more than 101 from one project). The same feed, same 26 events (checked equal to the single query), now costs **1.3 ms for the first page and 1.3 ms
after 500,000 events**, about a hundred times less, and independent of the history: it grows with the number of projects the caller is in, not with how busy they are. Only `cursor=` uses it, because
the cutoff has to be pushed into each project's lookup; the offset path is untouched. Comments (bounded by one task's conversation), the inbox (pruned after 30 and 180 days), memberships and projects stay with offset: they do not grow without limit.

## A load test every night

Numbers on this page are from one laptop and go stale; the guard that does not is the nightly run: `.github/workflows/loadtest.yml` builds the same data set
on a CI runner, drives the same k6 script at 15 visits a second for 90 seconds and fails if any threshold in `loadtest/k6/api.js` is breached
([loadtest/README.md](../loadtest/README.md#in-ci-nightly)). Thresholds, not measurements, are what it enforces, because a shared runner's absolute latency
swings by up to ten times between runs (seen on this repository's first two runs), and a breach is repeated once on a fresh environment before the job fails. A failed nightly run opens an issue.

## Other performance guards that run in CI

- **Bullet** raises on N+1 queries and on unused eager loading in every request spec.
- New endpoints assert their query count (`count_queries` in `spec/support/query_helpers.rb`), so a loop
  that issues a query per row fails the build.
- Deep pages: `page=` costs more the deeper it goes (4 ms at offset 10,000, 14 ms at 49,000); the task list offers
  `cursor=` (keyset) for feeds and exports ([above](#deep-pages-offset-against-cursor)).
- The nightly load test ([above](#a-load-test-every-night)).

## Known limits of these numbers

- One run per configuration; there is run-to-run variance of several milliseconds at p95.
- Client and server share the machine and the CPU.
- A laptop SSD and local socket, not Aurora over a network: expect database round trips to cost more in EKS.
  The shape (what scales with data, what is flat) should carry over; the absolute numbers will not.
- The write path here does not include Solid Queue workers or webhook delivery.
