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
