# Runbook: high error rate

**Alerts:** `task-api-<env>-error-rate-over-5-percent`, `…-error-rate-anomaly` (CloudWatch); `TaskApiHighErrorRate` (Prometheus).
**Impact:** requests are failing with 5xx. Users see errors or retries.

## First five minutes

1. **Is it a deploy?** `kubectl -n task-api get rollouts,deploy` and Argo CD history. If a release finished or is canarying, **roll back**
   first, investigate after: revert the tag commit in Git (or abort: `kubectl argo rollouts abort api -n task-api`).
   Canaries abort themselves when the success ratio drops, so an error spike during a rollout often resolves alone.
2. **Which endpoint?** Grafana "Task API" → *Slowest endpoints* / request rate by status. Or Logs Insights:
   ```
   filter event = "action_controller.request_completed" and status >= 500
   | stats count() as errors by controller, action | sort errors desc
   ```
3. **One trace:** take a `trace_id` from a failing log line and open it in X-Ray: which hop failed (database, Auth, AI service)?

## By cause

| What you see | Likely cause | Do |
|---|---|---|
| Every endpoint, `PG::ConnectionBad` / timeouts | Aurora failing over or out of connections | Aurora events in the console; Grafana *Connection pool*; wait for failover (≈30 s); if saturated see [high-latency](high-latency.md) |
| `auth_unavailable` (503) on all authenticated calls | The API cannot fetch JWKS from the Auth service | `kubectl -n task-api get pods -l app.kubernetes.io/name=auth`; Auth logs; the API caches keys for 10 min, so brief Auth outages are survivable |
| Only `/api/v1/ai/*`, 503/502 | Bedrock throttling or an unusable model answer | [ai-provider-issues](ai-provider-issues.md) (these should not count toward the SLO of non-AI endpoints; check by controller) |
| One endpoint, `ActiveRecord::…` or `NoMethodError` | A bug in the latest release | Roll back; reproduce with the request id from the log |
| 5xx from the ALB with no app logs (`HTTPCode_ELB_5XX`) | No healthy targets | `kubectl -n task-api get pods`; Karpenter capacity (`kubectl get nodeclaims`); readiness probe failures |

## After

Add a regression spec; if detection was slow, tune the alarm; record the timeline.
