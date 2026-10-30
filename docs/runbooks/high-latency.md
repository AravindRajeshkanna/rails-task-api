# Runbook: high latency

**Alerts:** `task-api-<env>-latency-anomaly` (CloudWatch); `TaskApiHighLatency` (p95 > 1 s for 10 min).

## Triage

1. Grafana "Task API": which `controller#action` is slow, and since when? Compare with the deploy time.
2. **Is it the database?** Grafana *Connection pool*: `busy` near `size`, or `waiting` > 0, means requests queue for a connection.
   Aurora: `ServerlessDatabaseCapacity` at its ceiling (`task-api-<env>-database-near-max-capacity`), Performance Insights top SQL.
3. **Is it a dependency on the request path?** Open a slow trace in X-Ray. The AI endpoints call a model (seconds, by nature);
   `/ai/chat` makes several calls. Their latency is expected to be high; confirm other endpoints are fine.
4. **Is it capacity?** `kubectl -n task-api get hpa,pods`; CPU throttling is not applied (no CPU limits), so look for nodes under
   pressure: `kubectl top nodes`.

## Actions

| Cause | Do |
|---|---|
| Missing index / slow query | Add the index in a migration (Bullet would have flagged N+1 in tests); `EXPLAIN` the query from Performance Insights |
| Connection pool exhausted | Raise `RAILS_MAX_THREADS` (and the pool follows) only with database headroom; otherwise add `api` replicas (HPA max) and raise Aurora `db_max_acu` |
| Aurora at max ACU | Raise `db_max_acu` in tfvars and apply; look for the query driving it |
| Under-provisioned API | Raise the HPA `maxReplicas` in `deploy/gitops/envs/<env>/api.yaml`; Karpenter will add nodes |
| A slow third party (Bedrock, SMTP) | Make sure the call is in a job, not the request; see [ai-provider-issues](ai-provider-issues.md) |

## When the API is refusing work (`TaskApiLoadShedding`, `503 overloaded`)

When every Puma thread is busy and two or more requests are already queueing for one, the API refuses the *expensive reads* (search, analytics, the activity feed, audit logs, GraphQL, AI) with `503 overloaded` and a `Retry-After` of one or two seconds, and keeps serving everything else: cheap reads, **every write**, sign-in and the health checks
([ADR 62](../decisions.md)). It is a protection, not a fault: in a test with 90 searches a second against capacity for 60, cheap reads took 9.5 s without it and 44 ms with it.

- `taskapi_puma_backlog` and `taskapi_puma_busy_threads` are the signal; `taskapi_load_shed_total` counts what was refused. If the backlog is empty and requests are slow, this is not capacity: go back to the steps above.
- **Add capacity**: more `api` pods (the HPA's `maxReplicas`) is the fix; shedding buys the minutes it takes. One client in a loop (check `taskapi_http_requests_total` by token in the logs, or the throttle: `429` on `api/expensive`) is the other cause.
- The threshold is `LOAD_SHED_BACKLOG` (default 2); `LOAD_SHEDDING=false` switches it off without a deploy of code (a config change). Do not switch it off during an overload to "let the searches through": they were the problem.
- `429 rate_limited` with "This organization has made too many changes" is a different thing: one organization spent its budget of writes for the five-minute window (`ORG_WRITES_PER_5_MIN`, 3,000). Look for an integration or a bulk script; the response's `Retry-After` is the end of the window.

