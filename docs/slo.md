# Service level objectives

What "working" means, in numbers, and what the system does when it is not. [ADR 64](decisions.md) has the reasoning; the rules are `deploy/observability/prometheus/task-api-slo.yaml`, tested in `slo-tests.yaml`.

**These are targets that were chosen, not guarantees that were measured over months.** The service has not run for 30 days under real traffic. The numbers below are set where the measurements we have (the nightly load test, [performance.md](performance.md)) say they are comfortably met, and they should be revised after the first real month.

## Service level indicators (what is measured)

| SLI | Definition | Measured as |
| --- | --- | --- |
| **Availability** | the share of API requests that are not a server error | requests under `Api::V1::*` with status other than 5xx / all of them (`taskapi_http_requests_total`); health checks and the metrics scrape are not requests anyone waits on. `503 overloaded` and `503 read_only` count as errors: to the person it was a failure |
| **Latency** | the share of API requests that complete within 500 ms | `taskapi_http_request_duration_seconds_bucket{le="0.5"}` / `_count`, same controllers |
| **Event freshness** (not an SLO yet) | how old the oldest unpublished event is | `taskapi_outbox_oldest_pending_event_age_seconds`; pages at 5 minutes (`TaskApiEventOutboxStuck`) |

## Objectives, over a rolling 30 days

| SLO | Target | Error budget | In plain terms |
| --- | ---: | ---: | --- |
| Availability | 99.9% | 0.1% of requests | about 43 minutes of total outage a month, or 1 request in 1,000 |
| Latency | 95% within 500 ms | 5% of requests | measured today: p95 30 ms on a laptop, 62-195 ms on a shared CI runner |

Client errors (4xx) are not failures of the service: a request for something that does not exist, or that you may not do, was answered correctly.

## Alerts: how fast the budget is going, not how bad the last five minutes were

A threshold alert ("5% errors for 5 minutes") misses the leak that spends the month's budget over a week, and pages for a blip that cost nothing. Each alert here is a *burn rate* (the error ratio divided by the budget) over a long window and a short one **at the same time**: the long one says it is real, the short one says it is still happening, so an alert stops soon after the problem does.

| Alert | Burn | Windows | Spends | Budget lasts | Severity |
| --- | ---: | --- | --- | --- | --- |
| `TaskApiAvailabilityBudgetBurnFast` | 14.4x | 1 h and 5 min | 2% of the month in an hour | 2 days | **page** |
| `TaskApiAvailabilityBudgetBurnSlow` | 6x | 6 h and 30 min | 5% in six hours | 5 days | **page** |
| `TaskApiAvailabilityBudgetLeak` | 3x | 1 d and 2 h | 10% in a day | 10 days | ticket |
| `TaskApiAvailabilityBudgetDrip` | 1x | 3 d and 6 h | 10% in three days | 30 days | ticket |
| `TaskApiLatencyBudgetBurnFast` | 6x (30% slow) | 6 h and 30 min | | | ticket |
| `TaskApiLatencyBudgetDrip` | 1x (5% slow) | 3 d and 6 h | | | ticket |

Every one also requires more than 0.05 requests a second over the hour: three failures out of five requests is not an incident. A latency problem is never a page, because a slow API is a bad day, not an outage. The older threshold alerts (`TaskApiHighErrorRate`, `TaskApiHighLatency`) stay as a coarse backstop.

What the tests prove (against synthetic traffic with `promtool`, in CI): a steady 2% error rate pages within the hour; 0.05% never alerts however long it lasts; a two-minute blip of 30% errors does not page; a ten-minute total outage pages while it lasts and stops about five minutes after it ends; a steady 1% is a slow burn and not a fast one; ten requests an hour cannot page; health checks do not count; a latency problem is a ticket. Six deliberate breakages of the rules (a missing short window, a threshold far too low, no traffic floor, health checks counted, ...) each fail a test.

## The error budget policy

Written down so that nobody has to decide it during an incident:

- **Budget remaining**: ship as usual.
- **A page-level burn, or the budget more than half spent with the month not half over**: the next change to production is a fix or a rollback, and risky changes (migrations that rewrite tables, dependency upgrades, new infrastructure) wait.
- **Budget spent**: no changes except those that improve reliability until it recovers, and a write-up of what spent it ([the failover drill](runbooks/failover-drill.md) has the template).
- A burn caused by one of the *deliberate* refusals (`503 overloaded` in an overload, `503 read_only` in a promotion) still counts. If they keep spending the budget, the fix is capacity or the failover procedure, not the SLO.

## When the numbers stop arriving

Every alert on this page is computed from the API's own metrics. If Prometheus cannot scrape the API, those series stop, the ratios become absent, and an absent value cannot page: the alerts stay quiet precisely when nothing is watching. `TaskApiNotScraped` exists for that: it is a ticket when a scrape of an API pod has been failing for 15 minutes, or when no API pod is being scraped at all. Treat it as urgent even so: until it is fixed, the paging alerts cannot fire.

Look first at the status of the target in Prometheus (`up{pod=~"api-.*"}`), then at the cause that was real once:

- **403 on `/metrics`.** The pod demands `METRICS_TOKEN` (the chart gives it one) and the scraper did not send the matching token. The PodMonitor's `authorization` must point at the same Secret key the pod reads (`metrics.tokenSecret` in `deploy/helm/values/api.yaml`). When this was first written the PodMonitor sent nothing, so a deployed cluster would never have scraped the API at all; `spec/deploy/metrics_scrape_spec.rb` now fails if a release gives its pods the token and its scraper does not carry it.
- **Timeouts.** The NetworkPolicy must allow Prometheus's namespace in (`ingressFromNamespaces: [observability]`).
- **No targets.** The PodMonitor's labels must match the Prometheus the cluster runs (`release: kube-prometheus-stack`), and the pod names still start with `api-`; the alert selects on that prefix.

The same reasoning is why the alerts are tested with synthetic data *and* why the scrape configuration is tested separately: the first proves the rules are right given the series, the second proves the series will arrive.

## What this does not cover

Per-route or per-tenant objectives (one organization's bad day is inside the global number), a synthetic probe from outside (the numbers are the server's view: requests that never arrived are not in them, which is what [the failover drill's probe](runbooks/failover-drill.md) and the Route 53 health check are for), and the other services' SLOs (the Notification service's freshness is the outbox alarm; the AI service has its budget and its circuit breaker).
