# Resilience: every dependency, what happens when it is slow or down

A system fails at its edges: the calls it makes to things it does not control. This page is the inventory of those calls, and for each one what bounds the damage. The rule behind it
([ADR 58](../decisions.md), [59](../decisions.md)): **a dependency that is down must cost a request a few milliseconds and an error message, not a thread for thirty seconds.**

| Dependency | Timeouts | Retries | Breaker | When it is down |
| --- | --- | --- | --- | --- |
| **PostgreSQL** (primary) | pool checkout 5 s; statement timeout is the server's | none inside a request | none | Everything that needs data fails; `/readyz` goes red so the pod leaves the load balancer; with the database read-only the API answers writes `503 read_only` and serves reads ([ADR 46](../decisions.md)) |
| **Solid Cache** (cache database) | its own | none | none | Reads miss, writes are skipped; throttling counters stop counting; nothing fails (`ReadOnlyMode::CacheTolerance`, and the gem's failsafe for timeouts) |
| **AI service** (`ai_service`) | connect 3 s, read 30 s | none in the request; background embedding retries with jittered back-off | **yes**, 5 failures, then 30 s doubling to 5 min | `503 ai_unavailable` with a `Retry-After`; the rest of the API is unaffected |
| **Model provider** (`ai_provider`, Bedrock in-process) | connect 5 s, read 20 s, SDK retries twice | as above | **yes**, the same | the same |
| **Auth service** (JWKS keys) | connect 2 s, read 3 s | rate limited to one fetch per 30 s | not needed | Keeps verifying tokens with the keys it holds, for up to a day; fails fast (503) only if it never had them |
| **SNS** (events to other services) | connect 3 s, read 5 s, SDK retries twice | **the outbox**: exponential back-off with jitter, capped at 15 minutes | not needed: the outbox is the buffer | Events wait in the database and are published when it returns; the API is unaffected ([ADR 41](../decisions.md)) |
| **Webhook receivers** | connect 5 s, read 5 s | six attempts, polynomially longer, with ActiveJob's jitter | no (a per-host breaker is the next step) | Their own queue and threads, so a slow receiver cannot starve anything else; failures stay visible in the delivery log |
| **Mail** (SMTP/SES) | the mailer's | the job's | none | Mail is a background job on its own queue (`mailers`); a failing relay fills failed jobs, never a request |
| **S3** (attachments) | the AWS SDK's defaults | SDK | none | Uploads and downloads of attachments fail; tasks are unaffected |
| **Notification service** | (consumes events, nothing calls it) | SQS redrive, 5 receives, then the dead-letter queue | n/a | Mail is delayed, not lost |

## The bulkheads

A bulkhead keeps one failure from using up what everything else needs. Here they are worker pools with threads of their own (`config/queue.yml`):

| Pool | Queues | Threads | Why it is separate |
| --- | --- | ---: | --- |
| critical | `critical` | 1 | Publishing events to the other services, and the job that reports on the queue itself. Measured: behind six slow webhook jobs it started in 0.42 s with this pool and 12.85 s without |
| general | `mailers`, `default` | 3 per process | Mail people are waiting for, reminders and digests |
| webhooks | `webhooks` | 2 | Calls to other people's servers, which can be slow or hostile |
| low | `low` | 1 | Embeddings (a model call) and housekeeping: work that can wait, and must not be waited for |

The web tier has the same shape in miniature: Puma's threads equal the database pool (`RAILS_MAX_THREADS`), so a request never waits for a connection another request holds, and the load shedder ([rate limits and load](../performance.md)) refuses the cheap-to-refuse work first when threads run out.

## Graceful degradation, feature by feature

What still works when a dependency is gone, because the call is not on the path of the core feature:

| Down | Still works | Degraded |
| --- | --- | --- |
| AI provider or service | everything except `/ai/*`, task embeddings (they retry later), similar-task suggestions | `503 ai_unavailable` + `Retry-After` |
| Auth service (JWT mode) | requests with a token signed by a key already held | sign-in and refresh (they are the Auth service's) |
| SNS / the other services | the whole API | events and email from the Notification service are delayed |
| Cache | the whole API | slower: project statistics and counters are recomputed |
| Mail relay | the whole API | invitations and reminders are delayed |
| The standby region's database (read-only) | reads | writes `503 read_only` |
| Search index | n/a: it is a column in the same database | |

## What is deliberately not here

Retrying a request inside a request (it multiplies load on a struggling dependency, which is when it is least wanted: retries belong in jobs, with back-off and jitter), a shared breaker state (per-pod state needs nothing else to be up to work), and a service mesh.
