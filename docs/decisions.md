# Architecture decisions

Short records of the choices that shaped this codebase: what we picked, why, and what it costs.
Newest thinking wins; if a decision changes, edit its entry and say so.

1. [API-only Rails 8.1 on PostgreSQL](#1-api-only-rails-81-on-postgresql)
2. [URL versioning: `/api/v1`](#2-url-versioning-apiv1)
3. [Database-backed bearer tokens, not JWT](#3-database-backed-bearer-tokens-not-jwt)
4. [Pundit, and 404 instead of 403 across tenants](#4-pundit-and-404-instead-of-403-across-tenants)
5. [Alba serializers and a `{data, meta}` envelope](#5-alba-serializers-and-a-data-meta-envelope)
6. [Pagy offset pagination](#6-pagy-offset-pagination)
7. [One error envelope, including errors outside controllers](#7-one-error-envelope-including-errors-outside-controllers)
8. [The Solid stack instead of Redis](#8-the-solid-stack-instead-of-redis)
9. [Domain events through `Rails.event`](#9-domain-events-through-railsevent)
10. [Webhooks: signed, retried, SSRF-guarded](#10-webhooks-signed-retried-ssrf-guarded)
11. [Soft delete, audit log, and Active Job continuations](#11-soft-delete-audit-log-and-active-job-continuations)
12. [Optimistic locking](#12-optimistic-locking)
13. [Testing strategy: specs that double as API contracts](#13-testing-strategy-specs-that-double-as-api-contracts)
14. [Inference lives in a gem, behind a gateway](#14-inference-lives-in-a-gem-behind-a-gateway)
15. [The model's output is untrusted input](#15-the-models-output-is-untrusted-input)
16. [Cost controls are part of the feature](#16-cost-controls-are-part-of-the-feature)
17. [pgvector, not OpenSearch, for embeddings](#17-pgvector-not-opensearch-for-embeddings)
18. [Amazon Lookout for Metrics was replaced](#18-amazon-lookout-for-metrics-was-replaced)
19. [Observability is built on Rails 8.1 events, with a thin layer of standards](#19-observability-is-built-on-rails-81-events-with-a-thin-layer-of-standards)
20. [Services share a small kit, not a framework](#20-services-share-a-small-kit-not-a-framework)
21. [Strangler fig: Auth, then AI, then Notifications; Tasks and Projects stay](#21-strangler-fig-auth-then-ai-then-notifications-tasks-and-projects-stay)
22. [Auth: short-lived JWTs, rotating refresh tokens, a local projection of users](#22-auth-short-lived-jwts-rotating-refresh-tokens-a-local-projection-of-users)
23. [Events: CloudEvents on SNS, one SQS queue per consumer](#23-events-cloudevents-on-sns-one-sqs-queue-per-consumer)
24. [EKS Pod Identity, not IRSA](#24-eks-pod-identity-not-irsa)
25. [Karpenter, Spot by default, and a small on-demand system group](#25-karpenter-spot-by-default-and-a-small-on-demand-system-group)
26. [Argo CD, ApplicationSets, and Terraform that stops at the cluster edge](#26-argo-cd-applicationsets-and-terraform-that-stops-at-the-cluster-edge)
27. [The AIOps loop recommends freely and acts rarely](#27-the-aiops-loop-recommends-freely-and-acts-rarely)
28. [What was left out on purpose](#28-what-was-left-out-on-purpose)
29. [Strict RuboCop by extending omakase, not by switching to StandardRB](#29-strict-rubocop-by-extending-omakase-not-by-switching-to-standardrb)
30. [Commands, queries and forms: where logic goes, and what was not added](#30-commands-queries-and-forms-where-logic-goes-and-what-was-not-added)
31. [The database is the last line of defense, and migrations are written for a rolling deploy](#31-the-database-is-the-last-line-of-defense-and-migrations-are-written-for-a-rolling-deploy)
32. [HTTP caching: revalidate by body hash; no hand-made ETags, no fragment caches](#32-http-caching-revalidate-by-body-hash-no-hand-made-etags-no-fragment-caches)
33. [`secure_headers` with a deny-everything policy, because the API is never rendered](#33-secure_headers-with-a-deny-everything-policy-because-the-api-is-never-rendered)
34. [Organizations: a tenant boundary resolved in the policies](#34-organizations-a-tenant-boundary-resolved-in-the-policies)
35. [Joining an organization by invitation, with a signed token and no stored secret](#35-joining-an-organization-by-invitation-with-a-signed-token-and-no-stored-secret)
36. [Organization history lives in the audit log, with its own key](#36-organization-history-lives-in-the-audit-log-with-its-own-key)
37. [Teams: a second way into a project, resolved in the same two places](#37-teams-a-second-way-into-a-project-resolved-in-the-same-two-places)
38. [Full-text search: a stored `tsvector`, ranked, next to (not instead of) substring search](#38-full-text-search-a-stored-tsvector-ranked-next-to-not-instead-of-substring-search)
39. [The in-app inbox lives in the monolith, fed by the same events, independent of email](#39-the-in-app-inbox-lives-in-the-monolith-fed-by-the-same-events-independent-of-email)
40. [Keyset pagination as an option on the task list, built on Pagy's keyset paginator](#40-keyset-pagination-as-an-option-on-the-task-list-built-on-pagys-keyset-paginator)
41. [A transactional outbox for the events other services consume](#41-a-transactional-outbox-for-the-events-other-services-consume)
42. [Multi-region is designed, not built](#42-multi-region-is-designed-not-built)
43. [GraphQL: read-only, authorized by the policy scopes, with hard limits](#43-graphql-read-only-authorized-by-the-policy-scopes-with-hard-limits)
44. [A public demo is a mode, a reset and a recipe; hosting is the operator's](#44-a-public-demo-is-a-mode-a-reset-and-a-recipe-hosting-is-the-operators)
45. [Multi-region Terraform: one root module applied twice, and tested offline against mocks](#45-multi-region-terraform-one-root-module-applied-twice-and-tested-offline-against-mocks)
46. [A read-only mode for the promotion window, and what it took to make reads survive it](#46-a-read-only-mode-for-the-promotion-window-and-what-it-took-to-make-reads-survive-it)
47. [A copy of the backups in another region: AWS Backup for the database, a replicated bucket for the dumps](#47-a-copy-of-the-backups-in-another-region-aws-backup-for-the-database-a-replicated-bucket-for-the-dumps)
48. [The drill is measured from the client's side, by a probe, not by the people running it](#48-the-drill-is-measured-from-the-clients-side-by-a-probe-not-by-the-people-running-it)
49. [Notification settings: mutes decide what is written, the digest decides what is emailed](#49-notification-settings-mutes-decide-what-is-written-the-digest-decides-what-is-emailed)
50. [Paging the lists that only grow: a cursor everywhere it pays, a different query for the feed, and no cap on ranked search](#50-paging-the-lists-that-only-grow-a-cursor-everywhere-it-pays-a-different-query-for-the-feed-and-no-cap-on-ranked-search)
51. [Five GraphQL mutations that decide nothing (revisiting ADR 43)](#51-five-graphql-mutations-that-decide-nothing-revisiting-adr-43)
52. [Team maintainers manage who is on their team, and nothing else](#52-team-maintainers-manage-who-is-on-their-team-and-nothing-else)
53. [Teams nest one level, and the rule is written once](#53-teams-nest-one-level-and-the-rule-is-written-once)
54. [The demo front end is static files with no build step, and hosting stays the operator's](#54-the-demo-front-end-is-static-files-with-no-build-step-and-hosting-stays-the-operators)
55. [Idempotency keys: remember the answer, in the transaction of the write](#55-idempotency-keys-remember-the-answer-in-the-transaction-of-the-write)
56. [Sparse fieldsets that skip the work, not just the bytes](#56-sparse-fieldsets-that-skip-the-work-not-just-the-bytes)
57. [Index and write-path review: measure what each index costs, remove the one nothing reads](#57-index-and-write-path-review-measure-what-each-index-costs-remove-the-one-nothing-reads)
58. [Fail fast when a dependency is down: circuit breakers, stale keys and jittered retries](#58-fail-fast-when-a-dependency-is-down-circuit-breakers-stale-keys-and-jittered-retries)
59. [Worker pools are bulkheads: the queue a job runs in is a decision](#59-worker-pools-are-bulkheads-the-queue-a-job-runs-in-is-a-decision)
60. [Read replicas: opt-in, read-your-writes, and never a reason for a request to fail](#60-read-replicas-opt-in-read-your-writes-and-never-a-reason-for-a-request-to-fail)
61. [Caching is by key, not by delete](#61-caching-is-by-key-not-by-delete)
62. [Fair shares and refusing work early: budgets by organization and endpoint, and load shedding](#62-fair-shares-and-refusing-work-early-budgets-by-organization-and-endpoint-and-load-shedding)
63. [Liveness and readiness are different questions](#63-liveness-and-readiness-are-different-questions)
64. [Alert on how fast the error budget is going, and test the alerts](#64-alert-on-how-fast-the-error-budget-is-going-and-test-the-alerts)
65. [Capacity is arithmetic on measured numbers, with the database connection limit as the wall](#65-capacity-is-arithmetic-on-measured-numbers-with-the-database-connection-limit-as-the-wall)
66. [Sessions expire when unused, can be rotated, and can be listed and ended](#66-sessions-expire-when-unused-can-be-rotated-and-can-be-listed-and-ended)
67. [A person can be erased, and personal data has a retention that a job enforces](#67-a-person-can-be-erased-and-personal-data-has-a-retention-that-a-job-enforces)
68. [A scrape that cannot authenticate is silent: send the token, and alert when the numbers stop](#68-a-scrape-that-cannot-authenticate-is-silent-send-the-token-and-alert-when-the-numbers-stop)
69. [Encrypted columns take their keys from KMS, through a small provider of our own, and deterministic columns derive theirs from one wrapped master](#69-encrypted-columns-take-their-keys-from-kms-through-a-small-provider-of-our-own-and-deterministic-columns-derive-theirs-from-one-wrapped-master)
70. [One KMS key per purpose, the data key replicated for the standby, rotation by generation, and the use of every key watched](#70-one-kms-key-per-purpose-the-data-key-replicated-for-the-standby-rotation-by-generation-and-the-use-of-every-key-watched)
71. [One-click provisioning is a manual workflow over a one-time bootstrap, with no stored keys](#71-one-click-provisioning-is-a-manual-workflow-over-a-one-time-bootstrap-with-no-stored-keys)
72. [Only the owner reaches AWS: the lock is GitHub settings and the role's exact trust, and the repository is public](#72-only-the-owner-reaches-aws-the-lock-is-github-settings-and-the-roles-exact-trust-and-the-repository-is-public)
73. [A deployment smoke test is a fixed, throwaway environment that destroys itself, at the cheapest size that still has every kind of resource](#73-a-deployment-smoke-test-is-a-fixed-throwaway-environment-that-destroys-itself-at-the-cheapest-size-that-still-has-every-kind-of-resource)
74. [The local platform is proven by one scenario that runs unchanged on Docker Compose and on kind, and the first run is allowed to find faults](#74-the-local-platform-is-proven-by-one-scenario-that-runs-unchanged-on-docker-compose-and-on-kind-and-the-first-run-is-allowed-to-find-faults)
75. [The platform job runs in CI on credentials that belong to nobody, builds the images once for both stacks, and says what the platform said when it fails](#75-the-platform-job-runs-in-ci-on-credentials-that-belong-to-nobody-builds-the-images-once-for-both-stacks-and-says-what-the-platform-said-when-it-fails)
76. [The Platform jobs are watched, then required; Helm is pinned; and the settings script owns main's required checks](#76-the-platform-jobs-are-watched-then-required-helm-is-pinned-and-the-settings-script-owns-mains-required-checks)
77. [The local platform's leftovers: every service traces its requests, the dashboard's rules ship to Compose, a lost reset email is logged, one SMTP rule, and Traefik for ingress-nginx](#77-the-local-platforms-leftovers-every-service-traces-its-requests-the-dashboards-rules-ship-to-compose-a-lost-reset-email-is-logged-one-smtp-rule-and-traefik-for-ingress-nginx)
78. [Secret scanning in CI, a webhook secret replaced in two steps with both signatures in between, and no secret in an idempotency record](#78-secret-scanning-in-ci-a-webhook-secret-replaced-in-two-steps-with-both-signatures-in-between-and-no-secret-in-an-idempotency-record)
79. [Erasing a person across services: the outbox tells the Auth and Notification services, the tombstone keeps the subject, and JWT mode asks the Auth service for the password](#79-erasing-a-person-across-services-the-outbox-tells-the-auth-and-notification-services-the-tombstone-keeps-the-subject-and-jwt-mode-asks-the-auth-service-for-the-password)

---

## 1. API-only Rails 8.1 on PostgreSQL

**Decision.** `rails new --api --database=postgresql`, Ruby 4.0 pinned in `mise.toml`/`.ruby-version`, RSpec instead of Minitest.

**Why.** API mode drops the view and cookie stack we would never use. PostgreSQL gives us `jsonb` (audit changes, webhook payloads),
array columns (webhook events), partial/trigram indexes (task search), and it is what Solid Queue/Cache/Cable run best on in production.
RSpec because request specs read well and rswag builds on it.

**Cost.** Ruby 4.0 is new; every gem here was verified against it, but a team with older infrastructure may need Ruby 3.3+ (Rails 8.1 supports 3.2+).

## 2. URL versioning: `/api/v1`

**Decision.** Controllers live in `Api::V1`, inheriting `Api::V1::BaseController`, routed under `namespace :api { namespace :v1 }`.

**Why.** It is the most discoverable scheme (visible in logs, curl, docs) and costs nothing until a breaking change is needed.
When v2 arrives: add `Api::V2` controllers *only for the endpoints that change*, route the rest of v2 to the v1 controllers,
and share models, policies and queries. Resources (serializers) are the version-specific part, so give v2 its own where the shape differs.

**Policy.** Adding fields, endpoints, filters or enum values is non-breaking. Removing/renaming fields or changing semantics requires a new version.
Clients must ignore unknown fields.

## 3. Database-backed bearer tokens, not JWT

**Decision.** Rails 8's authentication generator is cookie-based, so we kept its shape (`User`, `Session`, `Current`, `has_secure_password`,
`authenticate_by`, `generates_token_for` password reset, `rate_limit`) and swapped the transport for `Authorization: Bearer`.
A `Session` row holds the SHA-256 **digest** of a 32-character random token; the plaintext is shown once.

**Why.**
- *Revocation is real.* Logout, password reset ("sign out everywhere") and expiry are a row delete; stateless JWTs cannot do this without a denylist, which is state again.
- *A database leak does not leak usable credentials.* Tokens carry ~190 bits of entropy, so an unsalted fast hash is appropriate (slow hashes are for low-entropy passwords).
- *Debuggable.* Sessions record IP and user agent; `last_used_at` is written at most every 5 minutes so reads don't become writes.

**Cost.** One indexed lookup per request. For this workload that is noise; at much larger scale put a short-TTL cache in front of `Session.authenticate`.
Tokens last 30 days (no refresh-token dance); a front end should treat a `401` as "sign in again".

## 4. Pundit, and 404 instead of 403 across tenants

**Decision.** One policy per resource, plus `Scope` classes that restrict queries to the caller's non-deleted projects.
`after_action :verify_authorized` / `verify_policy_scoped` on the v1 base controller makes forgetting authorization a loud failure.
Records outside your projects are `404`; records you can see but may not touch are `403`.

**Why.** Scoping at the query level means a bug in a controller cannot *return* another tenant's row, and answering 404 stops attackers
enumerating ids. Pundit over Action Policy: smaller surface, plain Ruby, enough for two roles. The project is the tenant boundary.

**Cost.** Policies query the membership table (memoized per policy instance); list endpoints avoid per-row checks by relying on the scope.

## 5. Alba serializers and a `{data, meta}` envelope

**Decision.** Alba resources in `app/resources`, `serialize(root_key: :data, meta: ...)`. Alba is configured with the ActiveSupport JSON backend.

**Why.** Explicit serializers keep the response contract out of the models (unlike `as_json`) and out of templates (unlike Jbuilder);
Alba is among the fastest and has no DSL magic. The envelope leaves room for `meta` without ever changing the shape of `data`.

**Gotcha that bit us.** Alba's default backend uses the `json` gem, which renders `Time` as `"2026-10-29 01:00:37 UTC"`. The rswag schema
check (`format: date-time`) caught it; the `:active_support` backend gives ISO 8601 with milliseconds.

## 6. Pagy offset pagination

**Decision.** Pagy 43, `?page=&limit=`, default 25, max 100, plus RFC 8288 `Link` and `Total-*` headers.

**Why.** Pagy is tiny and allocation-light. Offset pagination supports "jump to page N" and totals, which UIs want, and our lists
(a project's tasks, comments) are bounded. Every sort adds an `id` tiebreaker so pages never overlap.

**Cost.** `OFFSET` degrades on very deep pages and `COUNT(*)` runs per request. If a list grows into the millions, move that endpoint to keyset pagination (Pagy ships one).

## 7. One error envelope, including errors outside controllers

**Decision.** `ErrorHandling` (`rescue_from`) covers errors inside controllers; `config.exceptions_app = routes` + `ErrorsController` covers
what controllers never see (unknown routes, unparseable JSON, unexpected 500s).

**Why.** Clients write one error handler. 500s never leak exception text. Two production bugs were found only because a spec
simulates production exception handling (`show_detailed_exceptions = false`): Rack's status table is binary-encoded
(breaking `parameterize`), and reading `params` while rendering a *parse* error re-raises the parse error.

## 8. The Solid stack instead of Redis

**Decision.** Solid Queue (jobs), Solid Cache (`Rails.cache`, rate-limit counters), Solid Cable (WebSockets), each on its own PostgreSQL database in production.

**Why.** One datastore to run, back up and monitor. Throughput needs here are modest, and Rails 8 makes this the default path.
`SOLID_QUEUE_IN_PUMA=true` runs the job supervisor inside the web container, so a single-server Kamal deploy is one container plus Postgres.

**Cost.** Polling-based Cable/Queue add latency (~0.1-1 s) and database load versus Redis pub/sub. If real-time fan-out or job volume grows
substantially, swap the adapters (`cable.yml`, `queue_adapter`) without touching application code, and split a dedicated `job` role in `deploy.yml`.

## 9. Domain events through `Rails.event`

**Decision.** Models call `queue_event("completed")` from in-transaction callbacks; the event is published with `Rails.event.notify` in `after_commit`
(dropped on rollback). Subscribers (`Events::LogSubscriber`, `BroadcastSubscriber`, `WebhookSubscriber`) react independently.

**Why.** Models do not know about WebSockets or webhooks; adding Slack notifications is a new subscriber, not a model edit.
Publishing after commit means listeners never see changes that were rolled back, and queueing from `after_update` rather than reacting in
`after_update_commit` avoids a subtle trap: `touch: true` (tasks touching their project) fires update-commit callbacks and leaves `saved_changes` stale.
Subscriber errors are reported, not raised, because the data has already committed (they do raise in tests, so bugs surface).

**Cost.** Subscribers run in the request thread; they only enqueue jobs or write one row, so that stays cheap. Subscriptions are made at boot, so restart the dev server after editing one.

## 10. Webhooks: signed, retried, SSRF-guarded

**Decision.** HMAC-SHA256 over `"<timestamp>.<body>"`, a `WebhookDelivery` row per attempt group, `WebhookDeliveryJob` with 6 attempts and polynomial back-off,
encrypted-at-rest secrets (Active Record Encryption), payload snapshotted at event time.

**Why.** The timestamp in the signed string lets receivers reject replays. A delivery log makes receivers debuggable without log access.
The secret must be readable to sign, so it is encrypted rather than hashed, and shown to the client only once.

**SSRF.** Users choose the URL, so `Webhooks::UrlGuard` resolves the host once, rejects private, loopback, link-local (cloud metadata), CGNAT, multicast and
IPv4-mapped IPv6 addresses, and `Net::HTTP#ipaddr=` connects to *that* address, closing the DNS-rebinding window. Development opts out via `config.x.webhooks.allow_private_networks`.

## 11. Soft delete, audit log, and Active Job continuations

**Decision.** `discarded_at` on projects and tasks (small `Discardable` concern, no gem); `Auditable` writes an append-only `AuditEvent` in the same
transaction; `PurgeDiscardedJob` hard-deletes after 30 days.

**Why.** Accidental deletes are common in task tools, so deletes are reversible; the retention window bounds storage and privacy exposure.
Hand-rolling both is ~60 lines, avoids default scopes, and keeps behaviour explicit (`kept` is spelled out at each query, and policy scopes hide
everything inside a deleted project). Audit events deliberately have no foreign key to the audited record, so history survives the purge.

The purge uses `ActiveJob::Continuable` (Rails 8.1): one `step` per table with the last id as cursor, so a deploy that stops the worker mid-run resumes
instead of restarting. A spec simulates the interruption.

## 12. Optimistic locking

**Decision.** Tasks have `lock_version`; clients send it back on `PATCH`; a stale value yields `409 stale_object`.

**Why.** Two people editing the same task is the realistic conflict here; last-write-wins would silently drop edits. It is opt-in per request (omit it to skip the check).

## 13. Testing strategy: specs that double as API contracts

**Decision.** rswag specs (`spec/api`) both exercise endpoints and validate responses against the OpenAPI schemas they publish; behavioural request specs cover
authorization matrices, filters and failure modes; Bullet *raises* on N+1 and unused eager loading; a spec fails when a route is undocumented;
CI regenerates the OpenAPI file and fails if it differs from what is committed.

**Why.** Contract tests found real bugs during development (non-ISO timestamps, an undeletable-attachment route) that behavioural tests alone had passed.
Making Bullet strict keeps list endpoints honest as they grow.

---

# Evolving into an AI-powered, microservice platform on AWS

Decisions 14 onward cover the second stage: AI features, observability, extracting services, and running on EKS.
The big picture is in [architecture/overview.md](architecture/overview.md).

## 14. Inference lives in a gem, behind a gateway

The model-calling code (prompts, tool schemas, output validation, Bedrock, an offline fake, embeddings, the evaluation
harness) is `gems/ai_core`: Rails-free, no database. The monolith talks to it through `Ai::Gateway`, which has two
adapters: **local** (the gem in this process) and **remote** (HTTP to `services/ai`, which hosts the very same gem).

**Why.** Extracting the AI service became a configuration change (`AI_GATEWAY=remote`) instead of a rewrite, rollback
is the same switch, and the extracted service cannot drift from what was tested in the monolith. Retrieval,
authorization, budgets and persistence stay with the data, in the monolith.

**Cost.** One more moving part (a path gem) and a wire format to keep stable ([service-contracts](architecture/service-contracts.md)).

## 15. The model's output is untrusted input

Every AI feature is a forced tool call whose answer is re-validated before it is used: enums, dates, ids and lengths are
re-checked, dates are computed by the app (never by the model), and an assignee the model invents is dropped. User text
reaches the prompt as escaped JSON inside an `<input>` block that it cannot close. The chatbot's tools run as the
signed-in user through Pundit, and there is no delete tool. See [architecture/ai.md](architecture/ai.md).

## 16. Cost controls are part of the feature

Per-user and per-project daily token budgets (from an append-only `ai_usages` ledger), a per-user request rate limit,
input size caps, response caching for summaries, and a Prometheus counter of spend. Budgets are soft limits: two
requests racing at the edge can overshoot by one call, which is cheaper than locking on the hot path.

## 17. pgvector, not OpenSearch, for embeddings

Task embeddings are a `vector(1024)` column with an HNSW index in the same PostgreSQL (Aurora supports pgvector).
Similar-task search is always scoped to one project, so the tenant boundary is a `WHERE`, and there is no second
datastore to run, secure and keep in sync. OpenSearch earns its place at much larger scale or for hybrid text search.

## 18. Amazon Lookout for Metrics was replaced

The roadmap names Lookout for Metrics for anomaly detection. AWS ended support in October 2025. The alarms use
**CloudWatch anomaly detection** instead (`ANOMALY_DETECTION_BAND`) on latency, error rate and queue depth, with
static alarms as a backstop. Custom models on SageMaker remain the option if CloudWatch's seasonal model is not enough.

## 19. Observability is built on Rails 8.1 events, with a thin layer of standards

Logs are the structured events (`Rails.event`) as JSON, carrying `request_id`, `user_id` and the OpenTelemetry
`trace_id`. Metrics are Prometheus (`/metrics`, private) fed by the same events; queue depth is read from the database
rather than counted in worker processes, so it is one consistent number. Traces are OpenTelemetry over OTLP to a
collector that exports to X-Ray (X-Ray-compatible trace ids and propagation). CloudWatch gets only what alarms need,
as Embedded Metric Format log lines, with no agent or API calls.

## 20. Services share a small kit, not a framework

`gems/service_kit` gives every extracted service the same JSON logs, `/metrics`, tracing setup and the JWT verifier.
The monolith keeps its own richer copies and uses only the verifier. The duplication is deliberate for now: moving the
monolith onto the kit is easy later and risky to do in the same change as the extraction.

## 21. Strangler fig: Auth, then AI, then Notifications; Tasks and Projects stay

The Task API remains the façade. Extraction order follows the roadmap: Auth (highest leverage), AI (isolates slow,
costly calls), Notifications (a pure event consumer). Task and Project logic stay in the monolith: they share a
transactional boundary (a task *is* in a project, with membership checks on every read), and splitting them now
would buy a distributed transaction and a join over HTTP in exchange for nothing. The seams (policies, events, the
`users` projection) are in place to do it later. [architecture/microservices.md](architecture/microservices.md).

## 22. Auth: short-lived JWTs, rotating refresh tokens, a local projection of users

The Auth service issues 15-minute RS256 access tokens (verified locally by every service from `/.well-known/jwks.json`)
and single-use refresh tokens with reuse detection (a replayed token ends the whole sign-in). The monolith keeps a
`users` row per identity, because foreign keys point at it. Pre-migration accounts link through a `legacy_id` claim, **never
by email**: an unverified email must not be able to claim an existing account. Cost of stateless access tokens:
logout takes effect after at most 15 minutes for tokens already issued.

## 23. Events: CloudEvents on SNS, one SQS queue per consumer

Services publish CloudEvents 1.0 to one SNS topic; each consumer owns a queue (with a dead-letter queue) subscribed with
a filter on the event type. Delivery is at-least-once, so consumers deduplicate on the event id in the same transaction
as their work. Notification events carry everything a message needs, so the consumer never calls back. Publishing
goes through a background job with retries (not inside the request transaction); a transactional outbox is the next
step if an event must never be lost across a database commit and an SNS outage (done: [ADR 41](decisions.md)).

## 24. EKS Pod Identity, not IRSA

Each workload's ServiceAccount maps to an IAM role through an EKS Pod Identity association: no OIDC provider per
cluster, no annotations to keep in sync, and roles are reusable across clusters. IRSA stays available through
`serviceAccount.annotations` in the chart.

## 25. Karpenter, Spot by default, and a small on-demand system group

Application pods run on nodes Karpenter provisions (Spot-preferred, consolidated, replaced monthly). A two-node
on-demand group runs Karpenter itself and the cluster add-ons. Stateless services tolerate Spot interruptions through
PodDisruptionBudgets, zone spreading and the interruption queue; a `critical` on-demand pool exists for prod.

## 26. Argo CD, ApplicationSets, and Terraform that stops at the cluster edge

Terraform creates AWS resources and the IAM that cluster add-ons need; it installs nothing inside Kubernetes. Argo CD
installs the add-ons and services from Git: dev syncs automatically, staging after a promotion pull request, production
only when a human syncs it, with a canary and automatic analysis. Non-secret values (ARNs, endpoints) are rendered
from `terraform output` by `deploy/scripts/render_gitops.rb`; secrets only ever live in Secrets Manager.

## 27. The AIOps loop recommends freely and acts rarely

On an alarm the RCA Lambda gathers evidence (alarms, error groups from logs, recent deploys, slow traces) and asks the
model for a validated analysis posted next to the alarm. The remediation Lambda has a two-entry playbook (raise the
worker floor, restart workers), each action idempotent, cooled down, reversed when the alarm clears, limited by RBAC to
two named objects, and a **dry run until explicitly enabled**. Neither can be triggered by the other's output.

## 28. What was left out on purpose

- **GraphQL**, a **public demo**, and an actual **deploy**: the roadmap's Phase 7 items were out of scope then (GraphQL and a demo mode came later, [ADR 43](decisions.md) and [44](decisions.md)); deployment is
  yours to run from the guide.
- **Service mesh** (Istio/App Mesh): mTLS and traffic policy are not needed for five services behind NetworkPolicies and
  signed tokens; App Mesh is also being retired by AWS. Revisit past ~10 services.
- **CloudFront**: there are no public static assets; the API sits behind the ALB and WAF.
- **Amazon MQ / Redis**: SNS/SQS cover messaging; Solid Cache/Queue cover caching and jobs.
- **Moving webhooks into the Notification service**: webhook configuration is project data owned by the monolith; the
  service handles email and Slack. The event stream makes that move mechanical when wanted.

---

# Hardening and growth

## 29. Strict RuboCop by extending omakase, not by switching to StandardRB

The codebase follows Rails' own style (`rubocop-rails-omakase`: spaces inside array brackets, indented `private` members).
StandardRB is zero-configuration, but it formats differently, so adopting it would rewrite nearly every file for no
change in behavior. Strictness comes from what is *enabled*, not from the style engine: omakase turns almost everything
off, so `.rubocop.yml` turns the Lint, Rails and Performance departments on and adds complexity limits (ABC 30, 20-line methods,
cyclomatic and perceived complexity 10; RuboCop's defaults are far tighter than anyone reviews to). That found real
things (assignments inside conditions, `update_columns` calls that needed a stated justification, a Lambda method taking six
positional arguments) and a number of false positives, handled by configuration with the reason written next to it
(`params.expect` is for nested form params and this API takes flat JSON; `find_by_password_reset_token!` is not a dynamic finder).
`rubocop-rspec` was tried in spirit and left out: its defaults (example length, one expectation per example) fight the
journey-style specs this suite relies on. Eight pre-existing methods over the limits are listed in `.rubocop_todo.yml` so that
**new** code meets the standard while the debt stays visible; the file only shrinks.

## 30. Commands, queries and forms: where logic goes, and what was not added

Controllers were already thin (authorize, query, render), so there was nothing to extract wholesale and a mass refactor would
have been churn. The convention is now explicit instead: **commands** (`app/commands`, `ApplicationCommand`) are multi-record
writes that must succeed or fail together (`Organizations::Create`, `AddMember`, `RemoveMember`); **queries** (`app/queries`)
return data without changing anything (`TaskQuery`, `Analytics::ProjectReport`); **forms** (`app/forms`, `ApplicationForm`) validate
input that is more than one model's attributes (`Analytics::ReportForm`). No interactor gem and no `Result` type: a command
returns its value or raises, and `ErrorHandling` already turns the exceptions into the one error envelope. `dry-validation` was not
added: ActiveModel validations cover the cases and every contributor knows them. A command does not authorize; the controller asks
Pundit first, so the policy stays visible at the HTTP boundary.

## 31. The database is the last line of defense, and migrations are written for a rolling deploy

Validations only guard paths that go through the model. `insert_all`, `update_columns`, a console, and any future service sharing
the database skip them, so the invariants that matter are also CHECK constraints (enum values, non-blank names, non-negative
counters, roles). They are added `NOT VALID` and validated in a second migration so that adding them never scans a table under a
heavy lock; `strong_migrations` enforces that pattern and its siblings (concurrent indexes, non-validated foreign keys, expand /
contract) and the rules are in a runbook. Indexes are added only when `EXPLAIN ANALYZE` on realistic data shows a scan: of the
hot queries, exactly one needed an index (the default task listing of a very large project, 10 ms to 0.05 ms), and speculative
ones were declined because each costs every write ([docs/performance.md](performance.md)).

## 32. HTTP caching: revalidate by body hash; no hand-made ETags, no fragment caches

`Rack::ETag` (already in the stack) hashes the finished body, so a `304` is correct by construction. A controller-level
`fresh_when` would also skip serialization, but it needs a key that covers *everything the representation depends on*: a task's
JSON includes its assignee's and creator's names, its tags, and signed attachment URLs, none of which touch the task row when they
change. A hand-built key would sooner or later serve stale data to someone. So responses are `Cache-Control: no-cache, private` with
`Vary: Authorization, Accept` (clients may keep a copy but must revalidate, shared caches may not store it) and anything carrying a
credential is `no-store`. There is no `Last-Modified` for the same reason. Fragment (Russian-doll) caching is skipped for task and
project JSON for the same dependency reasons; the two expensive computations are cached explicitly under a project-version key
(project statistics, the analytics report; tasks `touch` their project, which changes the key). Revisit if profiling ever shows
serialization, not queries, dominating: the fix is `touch: true` on the associations in the key, then `fresh_when`.

## 33. `secure_headers` with a deny-everything policy, because the API is never rendered

A JSON API has no scripts, styles, frames or forms, so its Content-Security-Policy is `default-src 'none'` (plus the directives that do not
fall back to it) and the rest of the headers say "do not frame, sniff or leak a referrer". The gem is used over Rails'
`default_headers` for what it adds: it validates the policy (it refuses a CSP that lets `script-src` fall back), it supports a per-request
override (Swagger UI at `/api-docs` is the one HTML page and needs a policy it can run under), and it mounts at the top of the stack, so the
headers are on answers produced before routing too (Rack::Attack's 429, Host Authorization). HSTS stays with `config.force_ssl`; two sources of
truth for one header is how they drift.

## 34. Organizations: a tenant boundary resolved in the policies

An organization has owners, admins and members. Its owners and admins **administer every project of the organization without being
added to each one**; plain members can create projects in it and see nothing else automatically (projects stay private to their members).
Two designs were possible: keep copies of that access as project memberships and keep them in sync, or *derive* it in the policy layer.
Copies drift (a missed callback leaves a former admin with access); derivation cannot, because there is nothing to keep in sync. It costs one
LEFT JOIN in `ProjectPolicy::Scope` and one clause in `member_project_ids`, which every child resource already scopes through, so tasks,
comments, tags, webhooks, Action Cable and the AI tools followed without changes, and `tenant_isolation_spec` proves it for every route.

Rules that keep the boundary meaningful: a project's organization is fixed at creation (moving it would drag its members and data across a
tenant line); a project of an organization only accepts members of that organization (a model validation, so only a bulk insert that skips
validations gets past it); removing someone from the organization removes their project memberships there and is refused while they still
own one of its projects; the organization keeps at least one owner (changes to owners take a row lock on the organization, so two owners cannot leave at the same moment) and cannot be deleted while it has projects; only owners delete and
restore its projects and grant roles above `member`. **Teams** (sub-groups inside an organization) were added later: [ADR 37](decisions.md).

## 35. Joining an organization by invitation, with a signed token and no stored secret

Adding a member by typing the email of an existing user tells the administrator whether that address is registered: `404` for an unknown
one, `201` or `422` for a known one. The fix is to stop answering the question. An *invitation* is addressed to an email address, not to a
user: the administrator gets the same `201` whichever it is, the address receives a link, and the only way to become a member is to present
that link while signed in as that address.

Mechanics that were chosen: the token is Rails' `generates_token_for` (signed, expires with the invitation, and bound to the row's accepted
and revoked state), so there is no token column to leak, no digest to compare, and the job queue never holds a secret: the mailer renders the
token when it runs, and a resend simply renders a fresh one. Redeeming requires the token *and* that the signed-in user's address matches the
invitation, because an unverified sign-up can claim any address and a forwarded mail should not be a way in; every failure (unknown, expired,
used, revoked, someone else's) is one `404`, so the endpoint reveals nothing about which invitations exist. One open invitation per address and
organization is a partial unique index; inviting again refreshes it, which makes "resend" and "change the role" the same call. Both ends are
throttled, because inviting is a way to make this server send mail to strangers, and redeeming is a way to guess tokens.

What was not done: the direct "add by email" to a *personal* project (no organization) is unchanged, because it is the original contract and
inviting people to a personal project is a different feature; inside an organization's project the answer for an unknown address now equals
the answer for a registered stranger. The remaining differences are listed under "Known gaps" in [security.md](security.md).

## 36. Organization history lives in the audit log, with its own key

Project and task changes already went to `audit_events`, found by `project_id`. Organization changes (a rename, an invitation, someone joining,
a role change, a removal) belong to no project, so the table gets a second optional key, `organization_id`, rather than a second table: the
append-only guarantee, the actor, the `[old, new]` change format and the pagination are all reused, and `Auditable` only learned two things
(`audit_organization_id`, and an opt-in `audit_destruction`). A member leaving is the event this history exists for, so deletions are
recorded for organization memberships and, since it was the same gap, project memberships; a record destroyed *as part of* a cascade (an
organization or a project being deleted, a user being deleted) writes nothing, because its trail is being unlinked in the same transaction and
the rows would point at nothing. The history is for **owners**, not admins: it names who promoted whom and holds the invited addresses, and
relaxing that later is a one-line policy change whereas tightening it is a breaking one. The activity feed is unaffected: it reads events through
projects, and these have none. The migration is the zero-downtime shape from the migrations runbook (nullable column, `NOT VALID` key
validated next, concurrent partial index, since nearly every row belongs to a project).

## 37. Teams: a second way into a project, resolved in the same two places

A team is a named set of an organization's members, and a *grant* (`ProjectTeam`) gives all of them a role in one project. The alternative was
copying the team into project memberships and keeping the copies in sync, which is the design ADR 34 rejected for organization admins, for the
same reason: copies drift, and a missed callback leaves a former team member with access. So a grant is data of its own, and access is *derived*
where it is already decided: `ProjectPolicy::Scope` (one more grouped join that yields at most one row per project, so lists never duplicate),
`member_project_ids` (which every child resource scopes through, so tasks, comments, tags, webhooks and the channel followed without changes) and
`role_in` (the per-record lookup). The role is the **highest** of a person's routes in. That rule exposed a latent inconsistency, which is fixed:
the per-record lookup used to take the first route that answered, so an organization admin who was also a plain project member was an admin in
lists and a member on a single project. `project_policy_team_spec` now asserts both lookups agree for every combination.

Rules that keep it sound: a team belongs to one organization and its members must be in that organization (validated when added, and ended
by `OrganizationMembership` whenever someone leaves, by any route, since a team membership outliving the organization membership would be a back
door); only a project of the team's own organization can be granted, and a project's organization never changes; names are unique per
organization ignoring case (a unique index on `lower(name)`); teams are managed by organization owners and admins, and a project's admins grant
them. Adding to a team is by `user_id`, and a user outside the organization gets the same `422` as an id that matches nobody, so teams add no
way to learn who is registered; the same goes for granting a team from another organization. **Participants** (direct members plus team members)
are who a task can be assigned to and who the AI assignee suggestions rank, because a team that can see a project but cannot be given work in it
would be a trap. Measured on the 149,000-task database: the whale project's task page costs the same with the extra branch (0.7 ms against 0.8 ms).

What teams are not: they have no roles of their own, cannot nest, and cannot be granted to a personal project (a project without an organization has no
teams to grant). Projects of an organization still cannot be given to a person outside it, with or without a team.

## 38. Full-text search: a stored `tsvector`, ranked, next to (not instead of) substring search

Substring search (`?q=`) cannot use an index for the description, matches letters rather than words, and cannot rank. Full-text search is
`websearch_to_tsquery` against a `tsvector` that PostgreSQL maintains itself: a **stored generated column** over title (weight A) and
description (weight B), indexed with GIN. A generated column rather than a trigger or a callback, because it is correct for every write including
bulk inserts and never drifts, and it is visible in `schema.rb`. The price is that adding it rewrites the table under a lock (3.7 s for 149,000
rows), so that migration is the one marked `safety_assured`, with the measurement beside it and the alternative in the migrations runbook.
`websearch_to_tsquery` because it accepts anything a person types (quotes, `or`, `-`) and never raises a syntax error. The language is fixed to
English in the expression; supporting more would mean a language column and a new vector.

`q` keeps its meaning: it is a documented contract, and substring is still the right tool for fragments like part of an id or a code. The new
behavior is `search=` on a project's task list and `GET /search` across every project the caller can see. Results come only through
`policy_scope(Task)`, so team and organization access apply and nothing else leaks; the ranking SQL is built with Arel from a quoted value,
the highlight SQL from sanitized fragments, and the term is capped at 200 characters. Highlights are **plain text with « » around matches**,
never HTML: there is nothing to inject, and clients escape fields like any other.

What it is not: no stemming for languages other than English, no typo tolerance or synonyms (that is a search engine's job), nothing for comments
or attachments, and a broad term in a very large project costs about 20 ms because every match is scored ([performance.md](performance.md)).

## 39. The in-app inbox lives in the monolith, fed by the same events, independent of email

Email and Slack are delivery: stateless, at-least-once, deduplicated by event id, which is why the Notification service owns them. An inbox is
*state*: one row per person per event, with read/unread, listed and counted on every page load. It belongs next to the data it points at (the
task, its project, the access rules that decide who may still see it), and putting it in the Notification service would mean that service
re-implementing project visibility or calling back into the monolith, which ADR 23 deliberately designs out (events carry everything, consumers never call back). So the monolith writes it, from the domain events it
already emits (`task.assigned`, `task.due_soon`, `task.completed`, plus `comment.created`), through one more `Rails.event` subscriber. That keeps it
working in `NOTIFICATIONS_MODE=local` and `remote` alike, and means a single-host Kamal deployment has an inbox too; email stays on its own switch.

Decisions that matter: **nobody is told about their own action**, and the recipient must be able to see the project *when the event happens*;
afterwards the policy scope hides notifications of a project you have left or that is archived, so the inbox never outlives the access. Each
notification carries a snapshot of the task title, project name and (clipped) comment, so listing is one indexed query with no joins to tasks and
an old item still reads sensibly (what it points at may since have been renamed). Reminders have a unique `dedupe_key` per person, task and due date,
so re-running the daily job cannot double-notify. Foreign keys cascade, so purging a deleted task or project, or deleting a user, needs no callback.
Read items are pruned after 30 days and unread after 180 (`PurgeNotificationsJob`), which bounds the table. New items are pushed to the person's
own Action Cable stream. Measured on 300,000 rows over 500 users: first page 0.8 ms, unread count 0.5 ms (a partial index on `read_at IS NULL`).

Not built: per-kind preferences or muting, digests, mentions, and counts per project; each is an addition to this table and subscriber rather than a redesign.

## 40. Keyset pagination as an option on the task list, built on Pagy's keyset paginator

Offset pagination is simple, gives a total, and is the default everywhere. Its cost is linear in the offset (13.8 ms at row 49,000 of one project,
[performance.md](performance.md)) and it repeats or skips rows when others are inserted or removed between requests. Keyset pagination
(`WHERE (created_at, id) < (cutoff)`) has neither problem and no total. It is offered where lists get long, the task list, as `?cursor=`: the **presence**
of the parameter selects it (empty for the first page), so existing clients and `page=` are untouched, and `meta` says `next_cursor`/`has_more` instead of
pretending to a total.

Pagy 43 has a keyset paginator, so this is built on it instead of a hand-rolled cursor. Two of its edges are handled here rather than hidden. Its default
JSON encoding of a cutoff keeps only milliseconds, which would skip rows that fall between the rounded cutoff and the real one, so values are serialized to
microseconds (`pre_serialize`) and a spec forces rows a few microseconds apart across a page boundary. And it compares whatever the cursor contains, so the
cursor is **validated before use** (a list of the right length whose elements have the right types) and anything else is a `400`; the values are bound,
never interpolated, so a forged cursor can only move the window inside rows the caller was already allowed to see. What it cannot do, the endpoint refuses
(`400`, saying why): sorts by relevance (an expression), `priority` and `status` (enums, which Pagy would compare as labels against integer columns) and
`due_on` (nullable). Cursors are not signed and not tied to the query that issued them; using one with other filters gives that other query's page from that
point, which is the client's choice, not an exposure. The other list endpoints keep offset only, because none can get long enough to matter yet.

## 41. A transactional outbox for the events other services consume

Until now an event was published after commit by enqueuing a job. Two ways to lose one: the process dies between the commit and the enqueue, and an SNS
outage outlasts the job's retries (it then sits in the failed jobs, which nobody reads). The fix is the standard one: write the event to a table **in the
same transaction as the change** and publish from the table afterwards. The event then exists if and only if the change committed, and a publisher that
fails simply tries again later.

How it works: `EventEmitting#queue_event` (and the assignment and reminder paths) call `Events::Outbox.record`, which builds the CloudEvents envelope **at
that moment** and inserts it into `outbox_events`. A snapshot, because an event that is sent an hour later during an outage should say what happened, not
how the task looks then (the assignee's email in `task.assigned`, for instance). That forces a rule: the envelope must see everything the save wrote, so
`Task` queues its events in `after_save` below `has_many_attached` (Active Storage saves attachments in its own `after_save`, after `after_create`), and a spec
fails if tags or attachments are missing from the snapshot. `OutboxRelayJob` is woken after the commit and swept every minute; it leases a batch of rows
(`FOR UPDATE SKIP LOCKED` plus a `locked_until`), sends them, and marks them published. A failure keeps the row with its error and backs off exponentially to
15 minutes; one bad row never holds up the others; a relay that dies loses only its lease. The reminder's id is derived from the task and due date, so re-running
the daily job is a no-op. Published rows are deleted after a week; pending ones never are.

What it does not do: **order**. SNS standard topics do not order, and the relay's batches and retries reorder further, so consumers use the envelope's `time` and
the current state, and deduplicate on `id` (the Notification service already did, which is why at-least-once was safe before and still is). **Exactly once**
is not available over SNS. Webhooks, Action Cable and the inbox stay on the in-process path, because they are local, fast and tolerate a lost message
(a client reloads); only the cross-service stream earned a table. Cost: one insert and an envelope build per event inside the write transaction, about 2.8 ms
(the build used to happen right after the commit, so request time is about the same, but row locks are held a little longer). The signal to watch is the age of the
oldest unpublished event (`taskapi_outbox_oldest_pending_event_age_seconds`, alarm at 5 minutes), because a growing count with a young oldest event is just load.

## 42. Multi-region is designed, not built

> **Superseded in part by [ADR 45](decisions.md):** the Terraform was built afterwards, at the owner's request. The reasoning below for why it was *not* built first still stands, and the caveat (nothing has been applied) is unchanged.

The roadmap listed multi-region as the last item, with the condition "only after a single region has run in anger". That condition still holds: the single-region platform has
never been applied to an AWS account. A second region built now would be Terraform written for a primary nobody has run, validated only by `terraform validate`, and its first
real test would be the incident it exists for. Unrun infrastructure is not a smaller version of working infrastructure; it is a liability that looks like an asset (a runbook
that has never been rehearsed fails in the same ways an untested backup does). So this ships as a **plan and a procedure**: [the design](aws/multi-region.md), [the failover runbook](runbooks/regional-failover.md),
both explicit that nothing in them has been run.

What the design commits to: active/passive warm standby (active/active would need conflict-free writes that nothing here has), Aurora Global Database for the data with an honest RPO
of seconds rather than zero, S3/ECR/Secrets Manager replication, a second EKS cluster from the same Terraform root, and a manual (or deliberately gated) failover. What already helps, and
was built for other reasons: the transactional outbox (unpublished events replicate with the database), idempotent consumers, tokens in the database and keys in Secrets Manager. What would
change in the code is small (a read-only switch is the one candidate); what would change in Terraform is the bulk, listed in the design. The cheaper alternative, cross-region snapshot copy,
is named as the first step and as the right answer if an hour of downtime is acceptable. Revisit when a region has run for a few months and the business states an RTO/RPO.

## 43. GraphQL: read-only, authorized by the policy scopes, with hard limits

The roadmap called GraphQL optional "when there is a consumer". There is not one yet; it was built because the cost of the design is low and its risks are knowable, and because the
alternative (wondering whether it could be done safely) is worse than a small, tested endpoint. The decisions that keep it safe: **read-only**: a mutation type would duplicate every REST write
and every validation, and the REST API already has the idempotency, locking and audit behavior; clients that need both use both. **Authorization is the policy scope**: a field resolves from `Pundit.policy_scope!`, so the answer to "what
may this person see" is the one code path REST uses, and a record you cannot see is `null` (REST's 404), indistinguishable from a missing one. There are no `authorized?` hooks per type, because a hook can be forgotten on the next type and a
scope cannot be skipped by starting from one. **Hard limits** (20 KB, depth 8, 1,500 complexity, page 100, one operation, auth required) because GraphQL lets a client ask for a graph, and an unbounded graph is the standard way to
take an API down. **No N+1** for people, tags and projects (the dataloader batches them, and a spec fixes the statement count); comments per task are the one honest exception, bounded by complexity. The user type has no
email field at all (only `Viewer`, i.e. yourself, does), so the only way to leak an address would be to add one.

Versioning follows the REST contract: additive changes only, and the schema is committed (`docs/graphql/schema.graphql`) and compared to the code by a spec so a change cannot slip by unreviewed. It lives under `/api/v1`, so
it carries the same `API-Version` headers and deprecation story. Not built: mutations, subscriptions (Action Cable already pushes events), persisted queries, a GraphiQL page (the introspection endpoint serves tools that want one).

## 44. A public demo is a mode, a reset and a recipe; hosting is the operator's

A public instance has three problems a private one does not: strangers can create accounts, strangers can use the server's resources for their own ends (mail, storage, outbound HTTP, a paid model), and strangers
leave a mess. `DEMO_MODE` answers them in the smallest way that keeps the demo honest: refuse, with an explicit list, exactly the routes that send mail, store files, call arbitrary addresses, spend AI budget or create accounts
(the list is data, checked against the real routes), reset everything every night, and let everything else be the real API. The shared, published password is a decision, not an oversight: a demo that needs sign-up needs an email
service, and a demo with private accounts needs everything this one deliberately does not have.

Two safeguards against the obvious accident: the reset **refuses to run unless `DEMO_MODE` is on** (so the nightly job and the rake task cannot wipe a real instance, which is what ships in `recurring.yml` for every environment), and the deployment is a Kamal
*destination* with its own service name, server and database, so it cannot share state with the real deployment by default. What was not done, because it cannot be done from a repository: hosting it, a domain, a front end (there is none here), abuse monitoring beyond rate limits.
`docs/demo.md` is the recipe.

## 45. Multi-region Terraform: one root module applied twice, and tested offline against mocks

ADR 42 declined to write Terraform for a second region before the first had run. It was written anyway when asked for, so the useful question became how to write it so that its mistakes show up *before* an account does.
Two decisions follow from that.

**One root module, two states, a `dr_role`.** The alternative, a separate `terraform-dr/` module, would duplicate network, EKS, WAF, messaging and observability and then drift. Instead the standby is this code applied with `dr_role = "secondary"`, `region`, and
`-dr` on every name (so the account-global names cannot collide), and the few things that differ are `count`s on the role: no secrets, signing key, SES user or deploy role in the standby; a secondary member of the global database with its own
KMS key; a replication rule in one direction on the primary and in the other on the standby, so failback is a switchover; Route 53 failover records owned by the primary's stack only. Alternatives rejected: **Aurora Global Database vs a
cross-region read replica**: global is the managed path with a promotion API and typically sub-second lag; **active/active**: nothing here is conflict-free; **automatic database failover**: a wrong automatic promotion loses data, a slow human one loses minutes, and
only the second can be undone, so DNS fails over by health check but the database and the scale-up stay manual. `dr_role` records how a stack was *built*, never who is *serving*: after a failover the roles swap in AWS and no Terraform change is needed or wanted.
The standby's state bucket is in the standby's region, because state that lives only in the failed region is state you cannot use during the failure.

**`terraform test` with mocked providers, in CI.** `terraform validate` cannot see most of what this change is about: whether the right resources exist for each role. A test file plans and applies the whole configuration against mocked AWS providers
(no credentials, nothing created) for a single region, a primary before and after its standby is ready, and a standby, and asserts what each creates, what it is named, and which bucket it replicates to; invalid role combinations must fail validation.
The tests were mutation-checked (breaking the secrets gating, the load-balancer condition and the replication target each failed the right test). Building them found two defects in the existing single-region code that a real `terraform plan` would have hit: a
security-group rule description containing an apostrophe, which the AWS provider rejects, and certificate-validation records keyed by values unknown until apply (now keyed by the one domain). What mocks cannot prove: that AWS accepts the settings (global-database engine versions,
Replication Time Control prerequisites, the ECR creation template), that IAM is sufficient, that timing works. Those are what the first apply and the drill are for, and why every document says *unapplied*.

Adding `count` to resources renames their addresses (`x` to `x[0]`), which for passwords, the signing key and IAM roles would mean destroying and recreating them in any stack applied from an earlier commit; `moved.tf` records the renames so nothing is replaced.

Not done: cross-account pairs (the ECR rule, replication roles and the ACM validation record assume one account), (a read-only switch for the promotion window, since built: [ADR 46](#46-a-read-only-mode-for-the-promotion-window-and-what-it-took-to-make-reads-survive-it)), automating the failover steps, and rendering a second Grafana/Prometheus view across regions.

## 46. A read-only mode for the promotion window, and what it took to make reads survive it

The standby region's database is a read-only replica until a person promotes it, and Route 53 can send traffic there before that (ADR 42, 45). The roadmap's answer was "a few lines of middleware turning `PG::ReadOnlySqlTransaction` into
`503 read_only`". The middleware is those few lines. What made reads actually survive was two other places that write on the way to answering a read, found by running the API against a database that really refused writes (a throwaway
database with `default_transaction_read_only = on`):

1. **`Session.authenticate` stamps `last_used_at`** (at most every five minutes per session). On a read-only database every signed-in read whose stamp was stale would have been a 503. The stamp is now skipped when the database refuses it, inside its own
   savepoint so that a refusal cannot abort a transaction the caller is in.
2. **Solid Cache gives up quietly on *transient* errors, and a read-only database is not one.** Rack::Attack's counters, `rate_limit` and cached project statistics all write to the cache, so every request would have raised, reads included, before reaching
   the middleware. A small module prepended to `SolidCache::Store` treats a refused write like the errors it already tolerates (skip the write, miss the read). It overrides one private method of the gem; a spec builds a real Solid Cache in the test transaction, makes the database
   read-only, and fails if the gem stops routing through that method. The cost: while it lasts nothing is rate-limited by the API (the WAF still is) and cached values are recomputed per request.

**Two entrances, one answer.** `READ_ONLY=true` runs each request inside `ActiveRecord::Base.while_preventing_writes`, so a write fails before it reaches the database; and a Postgres `25006` from a real replica takes the same exit.
(`ApplicationRecord.while_preventing_writes` looks like the narrower, safer call and does nothing: it is not a connection class here. The first draft used it and the specs caught it.) Both become the same `503 read_only` in the usual error envelope with
`Retry-After: 30`, counted in `taskapi_read_only_refusals_total{source}`, and a request that changed anything was rolled back with the exception, so a client retries it unchanged. Reads, GraphQL queries (which are POSTs, hence the database-level check rather than
an HTTP-method one) and existing tokens keep working. Signing in is a write and waits.

The standby renders with `READ_ONLY=true`; the production-size render (`SIZE_AS=prod`), which the runbook already uses as the "scale up" step, turns it off, and `READ_ONLY=true|false` overrides either way, which also drains writes before a planned
switchover. It covers the API only: workers are scaled by the runbook.

Alternatives: **no switch**, only the error mapping (rejected for the planned switchover, which should stop writes deliberately, not discover them); **a method check** (`POST` is not always a write; GraphQL); **a Rack-level `REQUEST_METHOD` filter** (same); **making the standby's
database writable by a second primary** (not available).
Not done: workers and Action Cable under a read-only database (jobs fail and retry until promotion), and exercising any of this against Aurora; it was checked against a local Postgres that refuses writes the same way (SQLSTATE 25006).

## 47. A copy of the backups in another region: AWS Backup for the database, a replicated bucket for the dumps

ADR 42 named this as the cheap first step of multi-region and the whole answer if an hour of downtime is acceptable. What it needs is not obvious, because Aurora's continuous backup (the 14 days of point-in-time recovery) **stays in the cluster's region**. Only snapshots can be copied out, and something has to take and copy them on a schedule.

**AWS Backup**, not a hand-written job: a plan with a daily rule and a `copy_action` to a vault in the other region, selecting the cluster. Alternatives: **an EventBridge-scheduled Lambda calling `copy-db-cluster-snapshot`** (code to write, test and keep working, to do what a managed service does); **a cross-region read replica** (a running cluster, which is the warm standby of ADR 42 at a different price); **`pg_dump` for Aurora** (works, but
a logical dump of a large database takes time and load that a storage snapshot does not). Each vault has a KMS key of its own region, because a copy is re-encrypted with the destination's. A failed backup or copy publishes to the alerts topic, since the failure that matters is the silent one.
The consequence worth stating: **the recovery point of the copy is the snapshot schedule** (a day by default, set it lower if the objective is lower; each snapshot is charged), not Aurora's five minutes, and the recovery time is a restore plus whatever
platform has to exist in that region.

**The dumps** get the same treatment for the Kamal host, which has no other off-machine copy: a versioned, expiring bucket replicating to a bucket in the other region, with deletions deliberately **not** replicated, and an IAM policy that can add objects and nothing else, so the host that writes
the history cannot read or erase it. The scripts that make the dumps real are `deploy/scripts/db_dump.sh` (a dump is read back and checked for the one table everything depends on before it is kept; optionally encrypted with age, so the bucket never holds plaintext; uploaded; a verified dump is kept if the upload fails because it is the only copy)
and `db_restore_check.sh` (restores into a scratch database and reports the time and the row counts, which is the rehearsal the runbook asks for monthly). They were run against the 149,000-task database: 7 MB in about a second, restored in 4 s with every row and pgvector.

Everything is off while `backup_copy_region` is empty, independent of `dr_role` (the cheap option must be usable without committing to the expensive one), and a standby creates none of it (the primary's cluster is what is backed up). `terraform test` covers it with mocked providers, mutation-checked (copy to the wrong vault,
replicating deletions, a readable upload policy, a standby that backs up each fail the right test). Not verified: that AWS Backup accepts a Global-Database member or a cluster with these settings, the restore commands, the IAM sufficiency of the service-role managed policies for the copy, and the real `aws` and `age`.

## 48. The drill is measured from the client's side, by a probe, not by the people running it

The roadmap item was "apply the pair in staging and run the drill". Neither can be done from a laptop with no AWS account, and the item's own condition (a single region that has run for months) is unmet, so what could honestly be built was what makes the first attempt cheap and its result a number: a `staging-dr`
environment (Terraform tfvars and backend, a GitOps environment rendered and CI-checked like the others, promotable from staging, synced automatically because a drill environment has no reason to wait for a person), a drill runbook with a record sheet, and `deploy/scripts/drill_probe.rb`.

The probe reads a project and creates a task every second, from outside the cluster, and reports what a user would have felt: each window in which reads or writes failed (and what the failures were: connection errors, `503 read_only`, a gateway error), the time from the first failure to the first tick where both worked, and, at the end,
which of the tasks the API **acknowledged** are no longer there. That last figure is the RPO in rows, measured, not inferred from replication lag. A drill measured by people with stopwatches and a feeling that "it was about ten minutes" teaches less than one with a log.
It is plain Ruby standard library (nothing to install on the machine that runs it), never raises on a network error (a failover is made of them), and writes only tasks titled `drill-<run>-<n>` in a project the operator names.

It ran against a live local server restarted into read-only mode and back (connection errors at each restart, 11 refused writes with reads working, 13 s to full service, 0 of 27 acknowledged writes lost), and the arithmetic of the report is covered by specs, with two mutations (an outage that ends a tick early; a refused write counted as acknowledged) each failing one.
What it cannot tell you: anything about AWS. That is what the drill is for.

## 49. Notification settings: mutes decide what is written, the digest decides what is emailed

The inbox (ADR 39) wrote everything and every kind of email went out. People need two controls, and they act at different points, so they are two things.

**Mutes** (`notification_mutes`: a kind everywhere, a project entirely, or one kind in one project; `NULLS NOT DISTINCT` makes "this whole project" one row, not as many as you click) decide **what exists**. A muted notification is never written to the inbox, never emailed and so never in a digest. The alternative, writing it
flagged "muted" and filtering on read, would keep every count and index honest about things nobody wants and make "unmute" ambiguous (do old ones appear?). Not writing it means unmuting affects what happens next, which is what people expect, and what is already in the inbox stays.

**The digest** (`notification_settings`: `off` or `daily`, an hour, a time zone) decides **how email is delivered**, not whether the inbox is filled. `daily` replaces the email per event by one summary of what is new and unread, sent in the hour the person chose in *their* time zone (the job runs hourly; a person is due when
their local hour matches and 20 hours have passed, which is robust to daylight-saving changes and to a run that is late). The digest is built from the inbox through the same policy scope as the inbox itself, so it needs no filtering of its own and cannot leak a project the person left. It is plain data handed to the mailer, not records, so a notification
pruned between queueing and rendering cannot fail the job, and it is queued under a row lock with a re-check so two overlapping runs send one. It is sent by this app in either `NOTIFICATIONS_MODE`: the mailer infrastructure is already needed for password resets and invitations, and the inbox it summarizes lives here.

**The Notification service.** In the production configuration the emails for assignments and reminders are not sent by this app but by the Notification service, which consumes the events and knows nothing about preferences. Rather than give it a copy of everyone's settings (state to synchronize), the event says so: `recipient.email_enabled`, computed from the settings at the moment the event is built (in the
transaction of the change, ADR 41). It is a field added to an existing object, so consumers that ignore it keep working, and the service treats "absent" as yes. The cost is that a setting changed after an event was written does not apply to that event, which is at most a delivery delay long (seconds, or the length of an outage).

**Cost.** Two indexed queries per event that notifies someone (`NotificationPreferences` loads settings and mutes for a whole batch at once; the daily reminder job does it once per 1,000 tasks, not once per task), nothing on requests that notify nobody.
Not done: per-channel preferences beyond email-or-digest (Slack is a project announcement, not a personal channel), a threshold digest ("when five things are waiting"), muting a single task (mute the project or the kind), preferences in the GraphQL schema (it is read-only and the REST API covers them), and applying mutes retroactively to the inbox.

## 50. Paging the lists that only grow: a cursor everywhere it pays, a different query for the feed, and no cap on ranked search

The roadmap said two things: cap the work of a broad ranked search "if one shows up in a p95", and add keyset pagination to other lists "if any grows past what offset serves". Both were measured before anything was built (numbers in [performance.md](performance.md#the-lists-that-only-grow-audit-logs-and-the-activity-feed)).

**Audit logs and the feed get `?cursor=`, reusing the task list's mechanism** (Pagy's keyset paginator, microsecond cutoffs, validated cursors). With 1,000,000 events in one project a first offset page costs 23 ms (23 of it the `COUNT(*)` for a total nobody reads) and the last 131 ms; keyset is 0.6 ms at every depth. Opt-in and additive, so clients that read `meta.count` keep working.
**Not the other lists:** comments are bounded by one task's conversation, the inbox is pruned, memberships and projects are small.

**The activity feed needed a different query, not just a cursor.** A cursor on the obvious query measured 108 ms against 109 ms for offset: PostgreSQL has no index that orders one table's rows across several projects, so for someone in eight projects it reads all 1.14 million events and sorts. Pagination was never the problem. `ActivityFeed` takes the newest 101 events of each project in index order and merges them
(101 because a page can be at most 100 and so can need at most 101 from any single project), which is 1.3 ms at any depth, identical results (checked against the single query, including ties in the same instant), and a cost that grows with how many projects a person is in, not with how much they have done. It is used only with a cursor, because the cutoff has to go inside each project's lookup;
`Pagination#paginate_by_cursor` takes a lambda for that, called after the cursor is validated, and Pagy's own `WHERE` on the outside is then redundant but harmless.
Alternatives: a global `(created_at, id)` index (PostgreSQL would walk it and discard other tenants' events: fast only if most events are the caller's); a materialized per-user feed (storage and fan-out on write for a list that is read rarely); denormalizing events per member. All cost more than the lateral query and need a reason this one does not.

**Ranked search is not capped.** Ranking only the newest 1,000 matches made a common word in a 50,000-task project 9 times faster (21 to 2.4 ms) and made no difference across projects (22 to 23 ms), which is the slow shape: there the time is finding the matches, not scoring them. It would also have changed what a search returns, for a saving that is not a problem anywhere
(p95 195 ms against a 600 ms limit, on seed data in which every common word matches 59% of rows). The roadmap's lever was right about the mechanism and wrong about where it applies; the next lever, if cross-project search is ever the slow one, is to require a project for broad queries or to add an index that answers "newest matches first" across projects. Recorded so nobody builds the cap on the strength of the old note.

## 51. Five GraphQL mutations that decide nothing (revisiting ADR 43)

ADR 43 left mutations out because "a mutation type would duplicate every REST write and every validation", and the roadmap said to add them "only if a client needs them". No client does yet; they were built because the work was asked for, and the design is chosen so that being wrong costs a deletion: the five mutations together are about 180 lines, comments included, nothing in them is a rule, and REST is untouched.

**Why they do not duplicate REST.** The REST writes turned out to be thin (build or find the record through the policy scope, `authorize`, `assign_attributes`, `save!`), because the rules are in the models and the policies. A mutation does exactly those steps and no others (`Mutations::BaseMutation`): the same `policy_scope`, the same `Pundit.authorize`, the same model save. So
validation, optimistic locking (`lockVersion`, `stale_object`), the audit trail with the right actor, the inbox, the events other services consume and the webhooks are the REST behavior because they are the *same code*, not because they were reimplemented. A spec runs the same mistakes through both APIs and compares the answers (a blank title, an assignee outside the project, a too-long title, duplicate tags), and
another asserts each mutation consults the policy by making it say no (the scope alone would not have caught a skipped `authorize`: every record a member can find, a member may update). Eleven deliberate breakages (a skipped scope, a skipped policy, validation or stale errors not mapped) each fail a spec.

**Errors.** Mistakes in what the caller sent are the payload's `errors` (`field`, `message`), REST's 422 `details`; problems with the request are top-level errors with `extensions.code`: `not_found` for a record that is missing and for one you cannot see, alike (REST's 404), `forbidden` (403), `stale_object` (409). A refused write while the service is read-only is the same `503 read_only` as REST ([ADR 46](#46-a-read-only-mode-for-the-promotion-window-and-what-it-took-to-make-reads-survive-it)):
the database refuses and the middleware answers, so the switch needed no GraphQL-specific code.

**One mutation per request**, because the rate limit counts requests and a REST request is one write. Without it a single request could carry as many writes as its complexity budget allows (`mutation { a: createTask(...) b: createTask(...) ... }`), which would turn a 600-per-five-minutes limit into thousands of writes. A query analyzer counts the mutation root's fields (fragments included) and refuses the request before anything runs.

**Why these five and no more.** Create, update and delete a task, comment, and mark a notification read: what a task-board client does all day. The rest of the write surface (projects, memberships, teams, organizations, invitations, tags, webhooks, attachments, AI) is administration, which REST serves as well and which has the sharper security properties (invitations answer identically for known and unknown addresses; uploads are multipart, which GraphQL
does badly). Each further mutation is ~15 lines and a handful of examples, so adding one when a client needs it is cheap; adding all of them now would be a surface to defend for no one.

**Subscriptions are still not built.** Action Cable already pushes the inbox (`NotificationsChannel`), a subscription would need its own stream authorization (a second place to forget a check), and nobody is subscribed. Not built either: persisted queries, batching, a GraphiQL page. Not verified: any real client, and mutation latency under load (a mutation costs what the REST write costs plus parsing).

## 52. Team maintainers manage who is on their team, and nothing else

A team (ADR 37) was managed entirely by the organization's owners and admins, which stops scaling when a hundred-person organization has twenty teams: the people who know who should be on "Payments" are not the organization's administrators. The roadmap asked for "team maintainers who manage membership". That is what a maintainer is, and the narrowness is the design.

**What a maintainer can do:** add and remove the *plain members* of their own team. **What they cannot:** make anyone a maintainer, change a role, remove another maintainer or themselves, rename or delete the team, grant it a project, or touch any other team. A maintainer who could appoint maintainers could grow their own circle without anyone administering it, and one who could change roles could promote
themselves back after an administrator demoted them; both are the privilege escalations this kind of feature ships with. So appointing is an administrator's act, and the policy spec states each "cannot" separately. (Plain members still cannot leave on their own, which was already the rule and is unchanged.)

**What the role does not do: grant access.** A maintainer gets no project access beyond what the team was granted, so being appointed never widens what a person can read. It manages membership, and membership *is* access (a person added to a team receives that team's project grants), so a maintainer can indirectly give someone access to everything the team has. That is the trust a team maintainer carries, and it is bounded: a person has to be in the organization already (the API says
the same thing for a stranger as for nobody), and only to teams the maintainer maintains.

The role is a column on the membership (`member` or `maintainer`, a check constraint added NOT VALID and validated in a second migration, like every constraint on an existing table), changes are audited like every other membership change, and `maintainer?` is a lookup of that one row for that one team, so being a maintainer of one team confers nothing on another and nothing once the person has left the organization.
Five deliberate breakages of the policy (maintainers manage nobody, can add maintainers, can change roles, are maintainers of every team, still count after leaving the organization) each fail a spec.

## 53. Teams nest one level, and the rule is written once

Organizations with departments want to grant a project to "Engineering" and have "Backend" and "Frontend" people get it without being added to Engineering twice. The roadmap's condition ("if organizations outgrow flat groups") has no evidence behind it yet; it was built because it was asked for, and because the cost and the risk could be measured and bounded, which is why it is shaped as it is.

**One level.** A team has at most a parent; a parent has none. Arbitrary depth needs a recursive query in the policy scope, which every request runs; one level is a single extra join, and it covers departments and teams, which is the use anyone has described. The validation says why ("teams nest one level"), applies both ways (a sub-team cannot be a parent, and a parent with sub-teams cannot become a sub-team), and a team with sub-teams cannot be deleted (a
validation and a foreign key with no `ON DELETE` action; the alternative, orphaning them, would silently change what their members can reach).
**Downward only.** Members of a sub-team have what the parent was granted, on top of what the sub-team was. A grant to the sub-team reaches only the sub-team, and being in the parent means nothing for the sub-team's grants. The opposite reading (parent members inheriting sub-team grants) is how a department head would see every project of every team below them with no one deciding that; if that is wanted, the head can be granted it.
**Same organization, one message.** A parent from another organization, one that does not exist, and the team itself get the same 422, so team ids cannot be probed across organizations.

**The rule is written once.** Access through a team was already computed in four places that must agree: the scope behind every list (`member_project_ids`), the per-record role lookup, the SQL in `ProjectPolicy::Scope` that annotates `current_role`, and `Project#participants` (who can be given work). Nesting changes all four, so they now ask two methods of `Team` (`granting_to(user)`: the teams a person is in and their parents;
`with_sub_teams(ids)`: a grant's teams and their sub-teams), and the spec that already checks the scope and the record lookup agree for every combination was extended to nested cases. Nine deliberate breakages (each of the four ignoring nesting, grants flowing the wrong way, the depth limit, the delete restriction, a parent from another organization) each fail a spec.

**Cost.** Measured on the 149,000-task database with 60 teams, 61 grants and a user in five sub-teams and two departments: the scoped task page of the 50,000-task project went from 0.97 ms to 1.34 ms (+0.4 ms), the team-reachable project ids from 0.41 to 0.57 ms, the project list stayed at 1 ms. That is a cost every request pays whether or not anyone nests, in exchange for the rule being in one place; it is small beside a 20 ms request and was the reason to stop at one level.
Not done: more than one level, a parent's maintainers managing its sub-teams' members (a maintainer manages their own team), grants to a parent being limited to some sub-teams, and listing a team's effective members (a sub-team's members are in `GET .../teams/:id/members` of the sub-team, not repeated under the parent).

## 54. The demo front end is static files with no build step, and hosting stays the operator's

The roadmap's last item was "hosting the demo, and a front end to point at it". Hosting needs a server, a domain and credentials, which only the operator has; ADR 44 already says what is provided (a mode, a reset, a Kamal destination). What can be built here is the client, and the choices about it are about what a throwaway demo should cost to keep.

**No framework, no bundler, no dependencies.** Three modules and a stylesheet: an API client, the screens as pure functions from data to HTML, and the glue. A framework would be the first thing to rot in a repository that has no JavaScript toolchain otherwise (no Node version to pin, no lockfile, no `npm audit`, no dependency updates); static files in ES modules run in any current browser and are tested with Node's own runner. The cost is writing
`innerHTML`, which is the classic way to ship cross-site scripting, so the screens are the only place markup is made, they are pure so they can be tested on their own, **every value that came from the API goes through one `esc()`**, and a test feeds hostile text through every screen and asserts no tag or attribute is injected. Task titles are other people's text, and in a shared demo that is the point.

**The token is `sessionStorage`, and the page cannot be pointed elsewhere.** A bearer token in `localStorage` outlives the tab and is the prize for any script that ever runs on the page; in `sessionStorage` it is gone when the tab closes. The API address is in `config.js`, written at build time, and deliberately not read from the URL: a link that could say `?api=` would turn the demo's sign-in form into a way to collect passwords on someone else's server. A strict Content-Security-Policy (own scripts and styles only; the API over https, or a local one) is in `index.html`, and `build.sh` refuses an API address that is not https.

**Found on the way: the API did not expose `X-Demo-Mode` to browsers** (CORS only exposes listed headers), so the banner it exists for could never have been shown by a front end on another origin. It is exposed now, with a spec.

**What was checked, and what was not.** The client was run against a real demo server with the real demo dataset (sign in, the board, create and move a task, a stale `lock_version` as 409, a blank title as 422, comments, the inbox, the demo's 403, sign out); CORS was checked with real preflights from the front end's origin (allowed, `X-Demo-Mode` exposed, another origin refused); and the app's DOM wiring was driven with jsdom (real clicks, form submissions and hash changes) against the same server, once, with jsdom installed outside the repository. The
repeatable tests (32, in CI) cover the client, the screens including hostile text, the app against a fake API, and the build script. **Not checked: how it looks.** The layout, the dark theme and the narrow-screen board have never been seen in a browser by whoever wrote them, so expect to adjust CSS. Not built: drag and drop, editing a task beyond moving it, search, a live inbox over Action Cable (polling every 30 s instead), and hosting.

## 55. Idempotency keys: remember the answer, in the transaction of the write

A client that times out on a POST cannot know whether it happened. If it retries blindly it may create the task twice, send the invitation email twice, or spend the model budget twice; if it does not retry it may lose the write. Idempotent *methods* cannot fix this (creating is not idempotent), and the exposed uniqueness rules catch only some duplicates (a duplicate task title is allowed). The standard answer is a client-chosen key, and the design choices are in what is remembered and when.

**Opt in per action, never by default.** `idempotent :create` on the controllers that create things. Not sign-in, registration or password reset, whose responses hold a credential that must not sit in a table; not uploads (multipart, large); not GraphQL (its mutations are one endpoint, and the header would have to be per mutation). A spec lists every controller with a `create` action and the ones deliberately left out, so a new create action must decide.

**What is remembered:** a fingerprint of the request (method, path and query, the raw body) and, once it succeeded, the response. The same key with a different fingerprint is `422 idempotency_key_reused`: replaying an answer to a different question is worse than refusing. A key is the caller's own (unique per user), so one person's keys cannot probe another's, and it expires after 24 hours (a daily purge).

**When:** the key is *claimed* first with an atomic insert (the unique index decides races, not a read followed by a write); a second request that finds a live claim gets `409 idempotency_in_progress` with `Retry-After: 1` rather than a replay, because there is no answer yet; a claim older than a minute belongs to a request that died and is taken over (compare-and-set on `locked_at`). The write and the stored answer then
**commit in one transaction**, so there is never a stored answer for a write that rolled back, nor a committed write with no answer (the failure mode of "write, then record"). Anything but a 2xx releases the key: a validation error should be retried after fixing, and a 500 should be retried as it is. Only successes are replayed.

**What a replay does not do:** it runs no policy, since nothing is read or changed; it returns the caller's own earlier answer to the identical request, which shows them nothing they were not already sent, even if their access has since been removed. That is the one place an action answers without authorizing, so it is explicit (`skip_authorization` with the reason) and the guard that every action authorizes (`verify_authorized`) stays on for everything else.

**Amended by [ADR 78](#78-secret-scanning-in-ci-a-webhook-secret-replaced-in-two-steps-with-both-signatures-in-between-and-no-secret-in-an-idempotency-record):** an action can name attributes of its answer that are shown the first time and not remembered (`idempotent :create, redact: :secret`). Webhook creation was opted in and its answer holds the signing secret, which broke the principle in the paragraph above; found by looking.

Cost: one insert per request that carries a key, and a transaction around that request; requests without the header pay nothing. Alternatives: storing the key on the created record (a column on every table, and no way to replay the response); Rack-level caching of POST responses (cannot be atomic with the write, and would cache failures); `If-None-Match`-style preconditions (they guard updates, not creation). Not done: keys for PATCH and DELETE (an update carries `lock_version`, which already makes a retry safe, and a repeated DELETE is a no-op), and keys on the services (they are internal and consume events at least once, deduplicated on event id).

## 56. Sparse fieldsets that skip the work, not just the bytes

A client that renders a list of titles and statuses should not download or make the server load a task's description, its tags, its creator, its assignee and its attachment blobs for a hundred rows. The roadmap asked for "filtering, sorting, and sparse fieldsets design"; the first two existed, the third did not.

**`?fields=a,b,c`, flat.** JSON:API's `fields[tasks]=` is for responses with several resource types; this API's envelope has one per endpoint, so a flat list is enough and easier to type. `id` is always included (a response you cannot key is useless). The resource declares what can be asked for (`sparse_fields`), a name it does not know is a `400` that lists the valid ones, and an empty or absent `fields` is everything, so existing clients see no change.

**Skipping the work needs two things, and the second is easy to forget.** Filtering the JSON after serializing saves bytes and nothing else. Here the resource's condition is evaluated by Alba *before* it computes a field (checked, not assumed: a block that logs when it runs does not run for a field left out), and the controller preloads only the associations the requested fields need. That second part is what the measurement shows: one query instead of five for `id,title,status`.
It is also not optional: the repository raises on an eager load nothing uses (Bullet), so loading the associations "just in case" would fail the test suite, rightly.

**Opt-in per resource, declared once.** `sparse_fields preloads: { assignee: :assignee, ... }` on TaskResource and ProjectResource; the DSL wraps each attribute and association declared after it, so a new attribute is selectable by default without anyone remembering to register it, and a spec fixes the field names of both resources so the list cannot change unnoticed. What a client may select is exactly what the resource already exposed: the creator and assignee are `{id, name}` and nothing else, and nothing in the list is an internal column.

Not done: nested selection (`assignee.name`), sparse fields on the other resources (comments, notifications and so on are small; the ones worth it are the two hot lists), and on GraphQL, which selects fields natively. The ETag differs between a sparse and a full response because the bodies differ, so conditional requests stay correct.

## 57. Index and write-path review: measure what each index costs, remove the one nothing reads

Phase 1 of the system-design roadmap asked for a schema review: normalization against denormalization, composite, partial and covering indexes "based on real query patterns", audit columns, multi-tenancy readiness, and eventual consistency of counts. Most of the schema already followed from earlier decisions (partial indexes on kept rows, composite `(project_id, ...)` indexes, soft deletes with a 30-day purge, `organization_id` on projects and audit events, a counter cache for comments). What was missing was evidence for the indexes, so each was priced
(numbers in [performance.md](performance.md#what-the-indexes-cost-measured)).

**Dropped: the trigram index on `tasks.title`.** It was added for the substring search, but that search ORs the title with an unindexed description, so PostgreSQL cannot use it, and did not: it cost 17% of every task insert and tens of megabytes for no read. The full-text index is the indexed search (ADR 38). The migration is reversible and concurrent. **Kept: everything else**, including the twelve prefix-redundant btrees: removing the largest was inside the measurement noise, and the usual argument for removing them (write
cost) is not measurable here. A review that deletes things to look tidy is a risk without a gain. **Not added: covering indexes and a `(project_id, title, id)` index**, which each save milliseconds on paths that are cached or rare and cost writes.

**Audit columns.** Tasks have `creator_id`; they deliberately have no `updated_by`. Who changed a record is answered by the append-only audit log (actor, action, before and after), which also says what was changed and survives later edits, whereas an `updated_by` column is only ever the last writer, is overwritten by the next one, and puts one more column on every update of a hot row. `deleted_at` is `discarded_at`, and the audit event for a deletion names who.

**Multi-tenancy readiness.** A project belongs to at most one organization, and everything else reaches its tenant through its project (`tasks.project_id`), so the tenant of every row is one join away and every policy scope already starts from the caller's projects. `organization_id` is *not* copied onto tasks and comments: it would be a second source of truth on the largest tables for the sake of a shard key that the project already is (see the machine-checked tenant map in [data-lifecycle.md](architecture/data-lifecycle.md)).

**Counts and consistency.** The cached project statistics are exact, not eventually consistent: tasks `touch` their project, which changes the cache key. The price was measured: a task write is 28% slower than it would be without the touch (780 against 1,077 creates per second with 8 writers), and, importantly, it does *not* serialize writers on one project (the same 780 per second whether the 8 share a project or not).
Eventual consistency (a counter table, a debounced touch, a short TTL) is the right trade only when a single project sustains hundreds of task writes per second; the documented trigger, not a guess.

## 58. Fail fast when a dependency is down: circuit breakers, stale keys and jittered retries

The failure that takes systems down is rarely a dependency being down; it is every request waiting out its timeout for it. A model provider that stops answering turns each AI request into a 20-30 second thread-hold (5 s to connect, 20-30 s to read, and the SDK retries twice), the pool of threads fills with waiting requests, and the endpoints that never touched the provider start timing out too. Three changes keep a bad dependency from becoming a bad API.

**A circuit breaker** (`ServiceKit::CircuitBreaker`, in the shared gem so the services can use it) around the two paths to the model: five consecutive failures open it, calls then fail at once for 30 seconds (doubling after each failed probe, to five minutes) with a `Retry-After` that says what is left, and exactly one probe call is allowed through to find out. Only infrastructure failures count (timeouts, a 5xx, the provider's own throttling): a caller's validation error or a model that answered
nonsense does not, or a few bad prompts would switch AI off for everyone. State is per process on purpose: the alternative, a shared store, makes the breaker depend on the thing that is failing, and each pod needs only five failed calls to learn. A breaker is not retry logic and not a queue: it is a decision to stop calling. Deliberately no admin switch to close it. State and transitions are metrics (`taskapi_circuit_breaker_state`), and a breaker open for five minutes tickets (`TaskApiCircuitOpen`).

**Stale keys instead of rejected tokens.** The JWKS cache expired after ten minutes and a failed refresh then rejected every request, even though the keys we hold are still right (a signing key is rotated on a schedule, not between two requests). Worse, every request retried the fetch, serialized on a mutex, so an Auth outage turned each authenticated request into a 5-second wait followed by a 503. Now a failed refresh keeps serving the held keys for up to a day (a revoked key must not live forever), and any fetch attempt, successful or not, is rate limited to one per 30 seconds; with no keys at all it fails fast rather than fetching again. A token signed with a key we do not hold is still refused.

**Jitter** on the one retry schedule that had none: the outbox's exponential back-off. Events that failed in the same second would all come back in the same second after an outage; "equal jitter" (half the delay fixed, half random, never above the cap) spreads them over the second half of each interval. ActiveJob's `polynomially_longer` already jitters by 15%. Retries inside a request are not added: they multiply load on a struggling dependency when it can least take it.

Not done: breakers on webhook receivers (per host, the next step) or on SNS (the outbox is already the buffer), and bulkheads inside the web tier beyond the database pool matching the thread count. Verified: the breaker against a fake clock (every transition, the single probe under 20 racing threads, the doubling and the ceiling), both gateways through a stubbed network, and the JWKS behavior; seven deliberate breakages of the breaker and four of the key refresh each fail a spec.

## 59. Worker pools are bulkheads: the queue a job runs in is a decision

One wildcard worker pool served every queue, so a backlog on any queue delayed all the others. Measured with real Solid Queue workers: six slow webhook calls (6 seconds each) enqueued before one event publication left the publication waiting **12.85 seconds**; with separate pools it started in **0.42 seconds**. Event publishing is the job that must not queue behind anything: it is the platform's link to the other services.

Five queues, four pools (`config/queue.yml`): `critical` (event publishing and the job that reports on the queue itself, whose silence would hide a jam) has a thread that nothing else can use; `mailers` and `default` (mail people wait for, reminders, digests) share the general pool, the only one that scales with `JOB_CONCURRENCY`; `webhooks` (other people's servers: slow, hostile, five seconds to connect and five to read) has two threads; `low` (embeddings, which are model calls, and housekeeping) has one. Framework jobs are placed too: mail on `mailers`, Active Storage analysis and purge on `low`.

**The risk of listing queues is a queue nobody listens to.** A job enqueued on an unserved queue sits forever with no error, which is the worst way for a background job to fail. A spec reads `config/queue.yml` and fails if any job (ours, mail, Active Storage) names a queue no pool serves, if a pool serves a queue nothing uses, if a queue is in two pools, or if the isolation properties are lost (critical alone with one thread, webhooks alone). The development and test configuration are the production one, so it is exercised before it is deployed.
Alternatives: job priorities within one pool (a long job already running still holds its thread, so priority does not isolate); one deployment per queue (isolation by process, at the cost of idle pods for each; the pools give the same protection inside a pod, and the worker Deployment can still be split later by passing different queues); a wildcard pool as a safety net (it would let slow jobs from other queues use the critical capacity).
Not done: autoscaling per queue (KEDA scales the worker Deployment on total backlog), and numeric priorities inside a queue.

## 60. Read replicas: opt-in, read-your-writes, and never a reason for a request to fail

A single writer serves every read in the system. The heavy reads (task lists, search, the activity feed, audit logs, analytics) are also the ones that tolerate a moment of staleness, so they can be moved to a replica to leave the writer's capacity for writes. Done carelessly it is the classic source of "I created it and it is not there".

**Opt-in per action** (`replica_reads :index, :show`), never by default and never for a write: the read-heavy actions of nine controllers are listed, and a spec fixes the list. **Read-your-writes:** whoever has written anything in the last three seconds (`REPLICA_READ_YOUR_WRITES_SECONDS`, set above the replication lag you see) is served by the primary, tracked with a cache entry per person that expires on its own; verified against a real streaming replica with its replay paused (simulating lag): a write is visible immediately, a read after the window is stale until replay resumes, which is the documented limit of the design. What is not promised: that one person's reads never go backwards between two replicas, or
that they see *other* people's writes instantly (they see them at replication speed). **Authentication happens first, on the primary**, so sessions (and their usage stamp, a write) never touch a replica.

**A replica must never be a reason for a request to fail.** If it cannot be reached, or the pool is exhausted, the request is served by the primary; if the replica cancels a query because it conflicts with replaying the primary's changes (a long query on a replica), the request is served by the primary too (and the replica is not blamed); after three unreachable failures in a row a circuit breaker stops trying for 15 seconds, then 30, up to two minutes. Verified by killing the replica under a running server: five requests, five 200s, three fallbacks, then the breaker open and the remaining requests not even trying.

**The mechanism** is Rails' own: a `primary_replica` database config with `replica: true` and `ApplicationRecord.connects_to`, switched with `connected_to(role: :reading)`, which also forbids writes on that connection (a routed action that tried to write would fail loudly in a test, not silently on a replica in production). Development and test point the reading role at the same database, so the routing runs in every environment; production gets a replica only when `DB_REPLICA_HOST` is set, which GitOps points at the Aurora **reader endpoint** (with one instance
it resolves to the writer, so enabling it is harmless before there is a second instance). Not routed: GraphQL (a POST, and its mutations write), anything that writes in a GET (the AI summary), and the workers.
Measured honestly: the routing check adds one cache read per routed request; the saving is the primary's capacity, which only matters when the primary is the bottleneck. It is the lever for a read-heavy load, not a speed-up for one request.

## 61. Caching is by key, not by delete

The caching strategy is written up in [architecture/caching.md](architecture/caching.md); the decision worth recording here is that **no cache entry is ever invalidated by deleting it**. Entries are keyed by a version of the data they were computed from, so a change makes the old entry unreachable and it ages out. That removes the forgot-to-invalidate and the concurrent-delete-repopulate bugs by construction, at a measured price (project statistics stay exact because every task write touches its project: 28% of task write throughput). Nothing public is cached at a CDN, because nothing the API returns is the same for every caller.

## 62. Fair shares and refusing work early: budgets by organization and endpoint, and load shedding

The existing limits stop one client (600 requests per five minutes per token, 300 per IP). Three things they cannot do, and what now does them.

**An organization is more than a client.** A hundred integrations of one customer, or a bulk import, can use up the database's write capacity for everyone, each of them well inside its own limit. Each organization now has a budget of changes (3,000 per five minutes, `ORG_WRITES_PER_5_MIN`), counted when a write is *authorized* (the record is known by then, so the organization costs no extra query, and authorization comes first, so a person who may not write cannot spend someone
else's budget). Reads are not charged (they can be served by a replica and are cheap to refuse), personal projects have no organization and are limited as a person, and the counter fails open: a cache outage should not stop people working. The same hook records `Current.organization_id`, which logs and traces now carry.

**Some requests cost thirty times others.** A search is ~50 ms and a project list ~10 ms, so a general budget of 600 lets a client spend all of it on the dearest endpoint. Search, analytics, the activity feed, audit logs and GraphQL have a smaller budget of their own (120 per five minutes per token), on top of the general one.

**Under overload, refuse the work that is dearest and easiest to retry, first.** When every Puma thread is busy and two or more requests are already waiting for one, taking more work makes everyone slower: the queue grows until requests time out. The shedder (a Rack middleware, before authentication so refusal costs almost nothing) answers the expensive reads with `503 overloaded` and a one-to-two second `Retry-After` (jittered, so refused clients do not all return together) and never sheds health
checks, metrics, sign-in or any write: a refused write is lost work, a refused read is a retry. The signal is Puma's own backlog; it is read only when running under Puma, and no signal means nothing is shed, never a guess. Measured with real Puma (3 threads), k6 and the 149,000-task database, 90 searches a second against capacity for ~60 plus 30 cheap reads a second for 25 seconds:

| | Cheap reads: median / p95 | Searches |
| --- | ---: | --- |
| Shedding off | **9,482 ms** / 10,463 ms | all queued, median 8.3 s |
| Shedding on | **44 ms** / 84 ms | 1,431 of 2,250 refused at once; the rest served in a median 43 ms |

The nightly load test (`loadtest/ci.sh`) runs with shedding **off**, deliberately: on a shared CI runner the same code answered with a p95 of 84 ms in one run and 210 ms in another, and in the slow run the Puma backlog reached the threshold (2) at only 15 visits a second, so the expensive reads were refused and a third of the search, analytics and activity checks failed. A benchmark whose verdict depends on the runner's luck measures the runner. The threshold of 2 is a chosen number, not a measured one; this is the first evidence about it, and it says a slow, shared machine crosses it at light load.

An earlier run of this experiment answered 500 to every request (a pending migration in the test database) and its numbers were thrown away: a load test that does not check its status codes measures a queue.

**The spec caught a bug in the signal itself.** The first version read `Puma.stats_object`, which is not a public reader; the error was rescued (the signal failing must not fail a request), so the shedder would have silently never shed in production. A middleware that fails safe is also a middleware that fails silently, so the default signal now has a test, and `taskapi_puma_backlog` is exported so that "the shedder sees nothing" shows up on a dashboard.
**Queue-based load leveling** is what the platform already does for everything that need not be synchronous: events go through the outbox, webhooks, mail, digests and embeddings through the worker pools (ADR 59), and the write path itself stays synchronous because the caller needs its answer. Not done: priorities between tenants under overload (every organization's expensive reads are shed alike), and shedding by queue time rather than backlog (Puma does not expose it).

## 63. Liveness and readiness are different questions

`/up` answered both, and checked nothing: a pod that could not reach its database was "alive", "ready" and in rotation, and the Route 53 failover check, which exists to notice a region that cannot serve, asked that same endpoint and so could not notice the commonest way a region cannot serve. Two questions, two endpoints (`HealthController`):

**`/livez`: is the process alive?** It looks at nothing outside the process. A failing liveness probe restarts the pod, so it must fail only when a restart is the cure; if it queried the database, a database outage would restart every API pod at once, which makes the outage longer (cold caches, reconnect storms) and cures nothing.
**`/readyz`: can this instance serve right now?** It runs `SELECT 1` against the database with a two-second ceiling. A failing readiness probe takes the pod out of rotation and leaves it running: a pod on a node with a broken route to the database is removed while the others serve, and rejoins by itself. It answers only "ok" or "failed" per check and never an error message, because it is unauthenticated and a message is reconnaissance.

Where each is used: Kubernetes readiness and startup on `/readyz`, liveness on `/livez`, the ALB target health check on `/readyz`, and the Route 53 failover check on `/readyz`. For that last one the consequence is the point: when the primary region's database is unreachable the region fails over, where before it passed `/up` and stayed. The check needs three failures 30 seconds apart, longer than an Aurora writer failover (30-60 seconds), so
a routine failover does not move DNS; a standby with a read-only database is ready (`SELECT 1` works on a replica). If *every* pod is unready the ALB, which fails open when no target is healthy, keeps routing to all of them and users get the application's own error, not a connection error.
`/up` is unchanged, for Kamal's zero-downtime check and anything already using it. Not done: draining (readiness going red on SIGTERM; the chart's `preStop` sleep covers it), readiness depending on the cache or the queue (both are tolerated, and a pod that cannot use them is still useful), and a liveness check that detects every thread being stuck (it would need a thread of its own, and under an overload it would restart pods precisely when capacity is short).

## 64. Alert on how fast the error budget is going, and test the alerts

The alerts were thresholds: "more than 5% errors for five minutes" pages, "p95 over a second for ten minutes" opens a ticket. Both are wrong in both directions. They miss a leak of 0.5% that spends the month's reliability over a week, and a two-minute blip can trip them for nothing. They also say nothing about what *good enough* is, so there is no basis for the argument "should we ship this now?".

**Objectives first** ([slo.md](slo.md)): 99.9% of API requests are not a server error and 95% complete within 500 ms, over 30 days; client errors are not failures; the deliberate refusals (`503 overloaded`, `503 read_only`) *are*, because to the person they were. The targets are chosen where the measurements we have say they are comfortably met, and the document says plainly that they have not been observed over a real month.
**Burn-rate alerts** (the multi-window, multi-burn-rate pattern from the SRE workbook): the error ratio divided by the budget, over a long window and a short one at once. Fast burn (14.4x over 1 hour and 5 minutes: 2% of the month gone in an hour) and slow burn (6x over 6 hours and 30 minutes) page; a 3x leak over a day and a 1x drip over three days open tickets. The long window says it is real; the short one says it is still happening, which is what makes an alert resolve soon after the cause is fixed. A floor of 0.05 requests a second keeps a few failed requests from paging. Latency alerts are tickets only.
Two details that matter: the denominator is not clamped (a threshold that divides by `max(rate, 1)` deflates the ratio at low traffic, and with no traffic the ratio should be *absent*, which cannot page); and the recording rules and the alerts that read them are in one group, since a group evaluates in order and separate groups run independently, so an alert would otherwise read the recording rule of the previous cycle.

**The alerts are tested.** An alert rule that has never been shown to fire is a hypothesis. `promtool test rules` feeds synthetic traffic and asserts which alerts fire at which minute: 2% errors pages within the hour; 0.05% never alerts however long; a two-minute blip of 30% does not page; a ten-minute outage pages while it lasts and stops soon after; a steady 1% is a slow burn, not a fast one; ten requests cannot page; health checks do not count; slow responses are a ticket. Writing them found that the first alert text claimed "over the last 5 minutes" while `$value` of an `and` expression is the long window's: the text was wrong and the test said so. Six deliberate breakages of the rules each fail a test. They run in CI.
The error budget policy (what changes when the budget is low or spent) is in the document, written down so that it is not decided during an incident. Not done: per-route or per-tenant objectives, an external synthetic probe as the SLI (the numbers are the server's view; a request that never arrived is not in them), and SLOs for the other services.

## 65. Capacity is arithmetic on measured numbers, with the database connection limit as the wall

"How many pods?" has an answer that is not a guess: one pod's measured ceiling (260 requests/s at the knee, 340 saturated), run at 70% of it at peak, sized so that losing a zone still carries the peak at 90%. `loadtest/capacity.rb` does that arithmetic and [capacity-planning.md](capacity-planning.md) states the assumptions next to it, so the numbers are not a spreadsheet nobody can audit.
The less obvious part is the other side of the fleet: every thread of every pod is a database connection, and Aurora's limit is a function of the ACU ceiling (about 1,800 at 8 ACU, capped at 5,000). A fleet that grows threads or pods without a pooler hits that before it hits CPU; the calculator reports the headroom and says what to do when it is negative. What it does not do is forecast: it does not know the traffic mix (search costs five times a list), table growth, or cost, and the document says to redo the measurement, not the arithmetic, when the shape of the load changes.


## 66. Sessions expire when unused, can be rotated, and can be listed and ended

A bearer token that was valid for 30 days from sign-in, whatever happened to it, had three weaknesses: a token that leaked and was never used by its owner again stayed good for a month; there was no way to replace a token you suspected without signing out and in (which a mobile client cannot do quietly); and a user could not see or end the sign-ins on a phone they had lost. The Auth service (JWT mode) already has the right shape for this (15-minute access tokens, rotating single-use refresh tokens with reuse detection), so the work is for the monolith's own sessions, and only there.

**Idle timeout, 14 days, on top of the 30-day absolute lifetime.** A session is live while it has not expired *and* was used within 14 days (`COALESCE(last_used_at, created_at)`; `last_used_at` is already maintained, at a coarse resolution, by authentication). A token that nobody uses dies at 14 days instead of 30, and one that is used keeps working until its absolute end. The same predicate is the `active` scope that authentication reads and the `expired` scope that the daily prune deletes, so what the API refuses and what the prune removes cannot drift apart. 14 days is a choice, not a measurement: long enough for a holiday, short enough to matter.
**Rotation: `POST /session/rotate`.** The caller trades the token it is using for a new one (same user, address and client, a fresh 30 days); the old one is deleted in the same transaction, so there is no moment with two valid tokens and no way for a failed request to leave the caller with neither. A client that rotates every few days limits what a leaked token can do to that interval. It is rate limited (30 an hour per user) so that a loop cannot churn the table. Rotation does not extend the absolute lifetime of a *stolen* token: the thief would have to rotate too, which kills the owner's copy, and the next time the owner calls they get a 401 and sign in again, which is the signal.
**`GET /sessions` and `DELETE /sessions/:id`.** The caller's own live sign-ins (address, client, created, last used, and which one this request is), and ending any of them. Scoped to the caller by the policy's `Scope`, so someone else's id is a 404 and not a 403, like every other record. The token and its digest are never in the response: they cannot be recovered, by design. In the public demo, where everyone shares one account, both endpoints are refused, since listing would show other visitors' addresses and revoking would sign them out.
**What it does not do.** In JWT mode these routes are not drawn (404), the same as sign-up and password reset, so there is one place that issues and ends credentials. It does not notify the user by email on a sign-in from a new place, does not tie a token to a device key (so a copied token works from anywhere), and does not revoke on suspicious use: all three are the next layer, and none is needed to make the three weaknesses above go away. A rotated session shows as a new row (a new `created_at`), so "signed in since" is not preserved across rotations.

## 67. A person can be erased, and personal data has a retention that a job enforces

Two questions had no answer: "how does a person's data leave?" and "how long do we keep what we hold?". Auditing every table against the jobs that prune it found three that grew for ever while holding personal data (the webhook delivery log, which stores a snapshot of every event including task and comment text; organization invitations, which store the email address of people who may never have signed up; and the Notification service's delivery log, which stores recipient addresses and whose one prune method, `ProcessedEvent.prune!`, was never called), and found that `User#destroy` could not work for anyone with history: tasks, audit events and projects point at the user with foreign keys.

**Erasure is anonymise-in-place, not delete.** `DELETE /me` (password required, 5 an hour) turns the user into a tombstone: `Deleted user`, an address on `.invalid`, no password, no `auth_subject`, `erased_at` set. Deleting the row would mean cascading into tasks, comments and the append-only audit trail, or nulling the keys that say who did what; both destroy more of other people's record than they protect. Deleted outright: sign-ins, memberships, inbox, preferences, mutes, idempotency keys, avatar, invitations addressed to them. Kept: what they wrote (it is the project's record), attributed to the tombstone. The alternative of deleting their comments was rejected because it rewrites conversations other people took part in; a project member can still delete any single item.

**Amended by [ADR 79](#79-erasing-a-person-across-services-the-outbox-tells-the-auth-and-notification-services-the-tombstone-keeps-the-subject-and-jwt-mode-asks-the-auth-service-for-the-password):** the tombstone *keeps* `auth_subject` (the paragraph above says it has none), `DELETE /me` works in JWT mode, and `user.erased` is written to the outbox and carries two ids (the paragraph on events says it carries one, and that the Notification service cannot act on it; since then it can).
**It refuses rather than orphan.** A person who owns an unarchived project, or is an organization's last owner, gets a 422 that names the thing (`owns_projects`, `last_organization_owner`) and nothing changes. The existing model guards (an owner cannot leave their project; the last owner cannot leave) already forbade the removal; checking first turns a half-finished teardown into a clear message. The cost is that, with no way to hand a project over (ownership is fixed for life), erasing an owner means archiving first.
**The audit trail is append-only, with one exception.** Invitations are audited with the invitee's address, so the address is removed from those entries (a JSON key delete; the entry that an invitation existed stays). That is the only place the trail is rewritten, in one method (`OrganizationInvitation.forget!`) used by both erasure and the retention job, so the exception has one definition.
**Events carry the id only.** `user.erased` has `user_id` and nothing else: the Notification service stores addresses, not ids, so it cannot act on the event, and putting the address on a queue in order to delete it elsewhere would spread the thing being removed. Its delivery log is bounded by retention instead (90 days), and that gap is written down.
**Retention is enforced by jobs, with the numbers chosen, not measured:** webhook deliveries 30 days, concluded invitations 90, the Notification service's deliveries 90 and processed events 14, run from the consumer loop because it is that service's only long-lived process. Measured: purging 350,000 of a million deliveries, with the oldest rows at the highest ids (the worst order for the query), took 1.3 seconds in batches of 5,000 and needed no new index.
**Did the tests prove it?** About twenty-five deliberate breakages across the erasure service, the retention jobs and the Notification service are each caught. Three were not at first, and each pointed at something real: a redundant line (leaving an organization already removes team memberships; deleted), an untested effect (the avatar purge), and the loop that was supposed to call the prune (no test ran the loop; there is one now).
**Not done:** export of a person's data, erasure in the Auth service and by recipient in the Notification service, ownership transfer, any retention for the audit trail (a policy decision, and the one table that is both large and permanent), automatic re-application of erasures after a restore. [data-protection.md](data-protection.md) lists what is held, for how long and what erasure does not reach; [architecture/data-lifecycle.md](architecture/data-lifecycle.md) has the growth arithmetic, the archival plan and the machine-checked map of which tenant owns each table.

## 68. A scrape that cannot authenticate is silent: send the token, and alert when the numbers stop

Writing the secrets-rotation runbook meant following `METRICS_TOKEN` from Secrets Manager to the pod, and it led nowhere: the chart injects the token into the API's environment, `Observability::MetricsApp` then answers **403** to any `/metrics` request without it (the private-address allowance applies only when there is no token), and the PodMonitor sent no credentials. In a deployed cluster Prometheus would never have scraped the API. Every `taskapi_*` metric, including the ones the SLO burn-rate alerts of [ADR 64](#64-alert-on-how-fast-the-error-budget-is-going-and-test-the-alerts) read, would have been missing, and because an absent ratio cannot page those alerts would have said nothing. The promtool tests could not catch it (they feed synthetic series), CI's chart validation could not (the manifest was schema-valid), and nothing had run in a cluster. It was found by reading, which is not a method.

**The fix has three parts.** The PodMonitor sends the token from the same Kubernetes Secret the pod reads it from (`metrics.tokenSecret`, a chart value, set for the API). A spec fails when a release's pods are given `METRICS_TOKEN` and its scraper is not configured to send it, and renders the chart (when `helm` is installed) to check the produced PodMonitor. And `TaskApiNotScraped` raises a ticket when a scrape of an API pod fails, or no API pod is scraped at all, for 15 minutes, with promtool tests for the failing pod, the missing fleet and the short blip; four deliberate breakages of the rule (the wrong state, no fleet handling, a one-minute wait, the wrong pods) are each caught.
**Alternatives considered.** Dropping the token and relying on the private-address check plus the NetworkPolicy would also work and is one fewer secret to rotate; it was rejected because the NetworkPolicy admits the whole `observability` namespace and the token costs one line of chart. A ServiceMonitor for the Service instead of a PodMonitor changes nothing about authentication.
**What it does not do.** The alert is a ticket, not a page: it is a fault in the monitoring and not yet user impact, with the cost that a pipeline blind for a night is noticed in the morning. The other services serve metrics with no token (their pods are given none) and are not covered by the alert. None of this has run against a real Prometheus; CI validates the rendered PodMonitor against its schema, and the first real test is the first deploy.

## 69. Encrypted columns take their keys from KMS, through a small provider of our own, and deterministic columns derive theirs from one wrapped master

[data-protection.md](data-protection.md) said it plainly: the only column the application encrypted was the webhook secret, with a key from the Rails credentials, and "a database reader sees names and addresses". The roadmap that prompted this work named two libraries, `active_kms` (preferred) and Lockbox with `kms_encrypted`. The source and README of both were read, and the first was also measured.

**What was found.** `active_kms` 0.3.0 is seven small files and a real gem. Run on Rails 8.1.4 against a counting stand-in for the KMS client, its provider made **one `Encrypt` and one `Decrypt` for a create** (its README says three and one, which is out of date), **one `Decrypt` for every row read** (101 rows, 101 requests), and **four `Decrypt`s to save a record whose attribute had been read**, even to change an unrelated column. It sends **no encryption context**, which the roadmap calls very important. It rescues every error from KMS, prints a warning and returns "no key", so Rails reports an outage or a denied permission as a decryption error. And it cannot help with the roadmap's own example: in Rails 8.1 `Scheme#key_provider` chooses `deterministic_key_provider` before the configured one, so `encrypts :email, deterministic: true` **never reaches a KMS provider**; it reads `deterministic_key` from the credentials.

**The decision.** `gems/kms_encryption` (a shared gem, like `service_kit`, so the extracted services can use it), about 480 lines including comments, with Rails doing the cryptography (AES-256-GCM) and KMS doing the key wrapping:

- **`KeyProvider`** for a value with a key of its own. One `GenerateDataKey` per write (a key in plaintext and wrapped, in one request). The wrapped key and the id of the KMS key that wrapped it travel in the value's header. The encryption context names the application, table and attribute. Unwrapped keys are cached for five minutes (1,000, least recently used out first), including the key just generated, because Rails reads back what it wrote. A failure is `KmsEncryption::Unavailable`, never a decryption error; a key that does not unwrap is `InvalidCiphertext`.
- **`StaticKeyProvider`** for deterministic columns. A 32-byte master is made once and wrapped by KMS; each process unwraps it once and derives a key per column with HKDF. **After that, no lookup, sign-in or listing makes a KMS request**, which is why there is no circuit breaker around KMS: the hot path does not call it. Measured: 20 µs to encrypt an address, 9 µs to decrypt, and no requests in 20,000.
- **`AwsClient`** with two-second timeouts and one retry (it runs inside requests), and **`LocalClient`**, an in-memory stand-in that behaves like KMS where the code relies on it (a different key or context fails to unwrap). It uses a public key, so the initializer refuses it in production.
- **Three key sources**, chosen explicitly: `kms` (when `KMS_KEY_ID` is set), `credentials` (Rails' own keys, for Kamal and docker compose, which are not on AWS and would otherwise stop booting), `local` (development and tests). Production with none of them has no source: the first use raises and `/readyz` fails, so a deployment that forgot cannot encrypt with the wrong key, and a pod with a wrong setting stays unready and the rollout waits.

**Measured, through the real AWS SDK against a KMS-compatible server:** creating a webhook is one `GenerateDataKey` and no `Decrypt`; reading its secret three times and saving it is one `Decrypt` (cache cleared first); 20 lookups and sign-ins make none; `/readyz` unwraps the master once.

**What is encrypted, and what is not.** `users.email_address` (deterministic) and `webhooks.secret` (re-keyed from the credentials key to KMS). Since [ADR 78](#78-secret-scanning-in-ci-a-webhook-secret-replaced-in-two-steps-with-both-signatures-in-between-and-no-secret-in-an-idempotency-record), also `webhooks.next_secret`, the secret being rotated in. Names are not (they are shown in every list and a ciphertext cannot be sorted). Task and comment text is not (every project member sees it, full-text search and the AI embeddings read it). **Invitation addresses are not**, deliberately: the same address is in the audit trail as plaintext, so encrypting the column would protect nothing; the audit trail is the open question, and it is a policy one. The roadmap's phone numbers, private notes and project credentials do not exist in this schema. [kms.md](aws/kms.md) lists the plaintext copies of an address that remain (audit trail, outbox for 7 days, the Notification service for 90, logs).

**Converting existing data** is done in place, in a window the build will not let anyone forget: `ENCRYPTION_ALLOW_PLAINTEXT` makes plaintext readable and queries match both forms, `bin/rails kms:encrypt` converts in batches, and a line in the GitOps values that opens the window must carry `# close by <date>`, after which CI fails. **Rehearsing it on a copy of the development database found a Rails bug**: with `normalizes` on the attribute (as `users.email_address` has), Rails' extended query casts its plaintext alternative to a string and then encrypts that, so a plaintext row is never found and anyone not yet converted could not sign in. Stock Rails 8.1.4 does the same for any `encrypts :v, deterministic: true` with `normalizes :v`. A narrow patch, active only while the flag is on and covered by a spec that fails if Rails changes what it relies on, fixes it (`config/initializers/encryption_transition.rb`); delete it when Rails does. A second finding from a spec: for a deterministic attribute with a previous scheme Rails keeps *writing* with the oldest one, so a master rotation would have read old values and never moved them; the model macro sets `fixed: false` while previous masters are configured.

**Alternatives considered.** *`active_kms` as it is*: rejected on the measurements above; it would have been the smaller change, and the numbers say its cost grows with the rows read. *Lockbox with `kms_encrypted`*: a different encryption stack for the whole application (a data key per record in a column of its own, searchable columns through a separate blind-index gem), a second mechanism beside the Rails encryption the project already uses, and, as its README describes it, a KMS `Decrypt` for every record whose key is read, with no cache documented. In its favour: its context names the model and the record, which the Rails provider interface cannot, and it lets encrypt and decrypt permission be granted separately (here that is possible per workload, not per process). It is the better choice if per-record keys or per-record audit are wanted. *The AWS Encryption SDK with a caching materials manager*: more complete (algorithm suites, committing encryption) and not integrated with Active Record. *`pgcrypto`*: the key would be in the database it protects.

**What it does not do.** The context cannot name the row, because Rails gives a provider no record and a new record has no id; a value can be copied between rows of the same attribute and still decrypt (as with Rails' native encryption). A process holds the master and any cached keys in memory for as long as it lives or the cache lasts, so revoking access in KMS takes up to five minutes to reach keys already unwrapped, and never reaches the master of a running pod. The Auth and Notification services, which hold addresses of their own, are not converted. There is no per-tenant key (ADR 70). Nothing here has run against AWS.

## 70. One KMS key per purpose, the data key replicated for the standby, rotation by generation, and the use of every key watched

The keys ADR 69 needs, and the other places a key was the missing piece. The Terraform is `kms.tf` and `kms_audit.tf`; it is validated and tested offline against mocked providers, and has not been applied.

**One key per purpose** so that what may use one cannot use another: **data** (the api and worker), **storage** (S3, on behalf of the api and worker; the Active Storage bucket moves from S3-managed keys to SSE-KMS, with a bucket key so S3 does not call KMS per object), **secrets** (External Secrets; Secrets Manager's secrets). Each rotates yearly.

**The data key is a multi-Region key, always.** The standby region reads the same Aurora database, so it must unwrap what the primary wrapped, and a single-Region key cannot be turned into a replicated one later (it would have to be replaced, with every value re-encrypted). The primary's stack makes the replica in the standby's region and the same aliases there, the way it already makes the secrets' replicas, so the standby's application is configured with the same alias and the standby's stack only looks the keys up. The storage key is not replicated (S3 replication re-encrypts each object under the other region's key, so the replication rule must opt in to KMS-encrypted objects, or S3 would quietly leave them out) and a standby's secret replicas stay under that region's AWS-managed key.

**Who may do what.** The key policy delegates to IAM, so access is granted where it is visible, and adds a statement no IAM policy can lift: **a request without `app = task-api` in its encryption context is refused, for everyone**. The api may `GenerateDataKey` and `Decrypt`; the worker may only `Decrypt` (it delivers webhooks and writes no encrypted column); the other services get nothing. `Encrypt` and `DescribeKey`, which the generic list in the roadmap includes, are not granted because the code calls neither. The grants name **key ARNs**: an alias in a policy's `Resource` does not grant access to the key. The application is configured with the alias. A spec per workload, in Terraform's own test framework, fails if any of this changes.

**Rotation.** Yearly rotation of the material is on and needs nothing from anyone. For an emergency, `data_key_generations` is a list in Terraform: adding `2` makes a new key and moves the stable alias in the same apply, so new values use it at once; the old key keeps decrypting (the grants list every generation) until `bin/rails kms:verify` and `kms:status` show nothing refers to it; removing `1` then schedules its deletion with a waiting period. The wrapped master is wrapped again under the newest key by the same apply (Terraform replaces its ciphertext when the key it names changes), so retiring a key never takes the only copy of the master with it. *Alternative:* `terraform apply -replace` on the key, which would destroy the old key while data still depends on it.

**Watching.** A CloudTrail trail that records **KMS events only** (an advanced event selector; a second account-wide trail of management events is billed as a second copy), kept in S3 and CloudWatch Logs, with alarms on the application's decrypt volume, on any refusal, and on any key or alias being disabled, re-pointed or scheduled for deletion (expected during a planned rotation). Every request the application makes carries its context, so "the application's decrypts" is a filter, not a guess. The application also counts its own KMS requests (`taskapi_kms_requests_total`), with two Prometheus alerts, tested with promtool. **The thresholds are chosen, not measured** (2,000 Decrypts in five minutes; 2 requests a second for 15 minutes). The design makes steady state a trickle; read the metric for a few weeks and set them to a multiple of the busiest ordinary window.

**Phase 7 of the roadmap, item by item.** *Files with KMS*: built (SSE-KMS, replication opted in, the api and worker may use the key only through S3). *Secrets Manager with a customer-managed key*: built for the primary. *Job arguments*: **audited, and nothing sensitive is passed**: every job takes a record, which travels as its id, or a timestamp, and mailers take records too; a spec fails if a job or mailer gains a parameter named like an address, token, secret or password, which is better than encrypting a value that should not be there. *Envelope encryption with data keys stored beside the data*: that is what the provider does. *Blind indexes*: not built: deterministic encryption answers equality, which is the only query on addresses; a blind index would add a column to support prefix or partial matches nothing needs. *Per-organization keys*: **design only, not built.** A KMS key per organization costs a key a month each and has a quota; rotation, replicas, grants and cache entries multiply by organizations; and because one application holds every grant, it does not limit what a compromised application can read. If a tenant needs it, the cheapest honest step is to add the organization id to the encryption context (so CloudTrail shows whose data was unwrapped), which needs the provider to be told the record, i.e. Lockbox-style per-record keys.

**What it does not do.** Nothing was applied to AWS. `kms:ViaService`, the metric-filter pattern on `requestParameters.encryptionContext.app`, the replica key, S3 replication with KMS and CloudTrail's selector are used as AWS documents them and not yet as AWS accepted them. The Terraform state holds the wrapped master's plaintext (as it holds the generated passwords and the Auth signing key); the runbook says how to rotate it. Tearing an environment down schedules its keys for deletion, after which any backup of an encrypted column is unreadable.

## 71. One-click provisioning is a manual workflow over a one-time bootstrap, with no stored keys

CI validated and tested the Terraform but nothing applied it, so bringing an environment up meant a laptop with administrator credentials and the setup guide's steps 2 to 4. The request was to run Terraform from CI, by hand, in one click.

**The decision.** `.github/workflows/provision.yml`, started only by `workflow_dispatch` (no push, pull request or schedule), for one environment at a time. It plans, writes the plan to the run's summary, and applies **the saved plan file**, not a second plan made later. `plan`, `apply` and `destroy` run from `main` only (the Environments accept no other branch, [ADR 72](#72-only-the-owner-reaches-aws-the-lock-is-github-settings-and-the-roles-exact-trust-and-the-repository-is-public)); `apply` and `destroy` also check it themselves; `destroy` also needs the environment's name typed again. One run per environment at a time, and a started run is never cancelled.

**No AWS key is stored anywhere.** The job trades GitHub's short-lived identity token for `task-api-terraform-<environment>`, whose trust names exactly one subject, `<prefix>:environment:<environment>`, where the prefix is what GitHub puts in this repository's tokens (`repo:<owner>@<id>/<repo>@<id>` since 2026-07-15; amended by [ADR 72](#72-only-the-owner-reaches-aws-the-lock-is-github-settings-and-the-roles-exact-trust-and-the-repository-is-public): the first version of this entry wrote the names, which this repository's tokens do not carry). The GitHub Environment is where approval lives: required reviewers on `prod`, and only `main` may deploy. **A role cannot create itself**, so a small CloudFormation stack (`deploy/bootstrap/bootstrap.yaml`, no state to keep) creates, once per environment, the identity provider, the state bucket (retained: it holds generated passwords and keys) and that role. The role is **administrator by default**: the configuration creates IAM roles, so any narrower policy that can create them can grant the rest; the protection is who can assume it, not what it can do. `PermissionsPolicyArn` narrows it for a team that wants to maintain that list.

**Environment-specific values need no commit.** The committed tfvars hold placeholders (`example.com`), so the workflow reads `TF_VARS_JSON` from the GitHub Environment (and optionally `TF_VARS_SECRET_JSON`) as var-files passed *after* the committed one, so they win. State lives in the bootstrap's bucket under `<environment>/terraform.tfstate`, the same key the committed `*.backend.hcl` files use, so a person and the workflow work on the same state. `replace` takes checked resource addresses for the rare targeted replacement (the master of ADR 69); inputs reach commands through environment variables and are never pasted into a script.

**Alternatives considered.** *Apply on merge to `main`*: rejected; an apply creates a half-hour of billable infrastructure and cannot be taken back by reverting a commit. *Terraform Cloud or Atlantis*: more machinery and another system to trust with administrator access. *A role Terraform creates for itself*: cannot exist before the first run. *Per-resource least-privilege policies*: see above.

**What it does not do.** It stops where Terraform stops: the per-service databases, Argo CD, and the two secrets only a person has are `kubectl` and `helm` steps, and the run's summary lists them in order. It does not enable Bedrock model access, verify SES or request quotas. `destroy` needs the cluster's own teardown first. **It has never run**: `actionlint` and specs pin its structure, the template passes `cfn-lint` and was created in a CloudFormation-compatible stand-in that applies neither managed policies nor parameter constraints, and nothing has run on GitHub's runners or in AWS.

---

## 72. Only the owner reaches AWS: the lock is GitHub settings and the role's exact trust, and the repository is public

The request was to allow only the owner to deploy and test on AWS. Reading what could reach AWS found more than a setting to flip:

- **The repository is public** and forkable, and `ci.yml` runs on every pull request. `deploy.yml` starts from `workflow_run` of CI, which runs with the repository's own permissions (an AWS token through OIDC, and write access to `main`) whoever started CI, and its `branches: [ main ]` filter compares the *name* of the triggering run's branch, so a pull request from a fork whose branch is called `main` satisfies it. It would have built the fork's code under the AWS role and written the fork's commit into `envs/dev` for Argo CD to roll out. Reasoned from the documented behaviour; **not demonstrated**.
- **The roles could not have been assumed by this repository.** It was created after 2026-07-15, so its tokens carry the owner's and the repository's IDs (`repo:AravindRajeshkanna@22373811/rails-task-api@1436955495:...`, read from the API), while both trusts (ADR 71's bootstrap role and the deploy role in `github.tf`) wrote `repo:<owner>/<repo>:...`. Every run would have been refused. The IDs are also the better lock: a deleted and re-registered name cannot inherit the trust.
- **GitHub creates an Environment, unprotected, the first time a workflow names it**, and the roles trust Environments by name. `dev` existed with no rule and administrators able to bypass; `staging`, `prod` and the standbys would have appeared unprotected on first use. No Environment had a deployment branch, and the trust cannot see the branch, so the Environment is the only branch rule.
- `github.tf` also trusted any run on `main`, with no Environment, hence no reviewer or branch rule. The actions that hold the token were referenced by tag, the repository token stayed on disk in the directory Docker builds read, and the default for fork pull requests was to approve first-time contributors only.

**The decision.** Layers, each of which would stop what the others miss:

1. **The code that holds the token.** `deploy.yml` builds only for a push, from this repository, to `main`, by the repository's owner (`triggering_actor.id == repository_owner_id`; anything else is skipped); permissions are empty by default, the AWS token goes to the build job only and write access to the job that commits the tag only; the build's checkout keeps no token. Every action in `deploy.yml` and `provision.yml` is pinned to a commit (a spec holds it), and no other workflow may ask for an AWS token.
2. **The trust, exactly.** One subject, matched with `StringEquals`: `<prefix>:environment:<name>`, in the bootstrap role and in the deploy role. No `ref:refs/heads/main` alternative, no wildcard. The prefix is not typed: the bootstrap stack requires it as an input you read from GitHub (`gh api .../oidc/customization/sub`), and the Provision workflow reads it from its own token and hands it to Terraform, after checking the token's subject has the one expected shape.
3. **The Environments.** All five exist before the first run, with deployment branch `main` only, the owner as required reviewer on `staging`, `staging-dr`, `prod` and `prod-dr` (not `dev`, which deploys by itself after every merge), and administrators unable to bypass. `deploy/scripts/github_settings.rb` states this as data, checks it read-only by default, and applies it with `--apply`. The same script reports, and does not change, who has access and whether `main` refuses force pushes and deletion.
4. **The workflow's own first step** refuses any account but the repository's owner, including a re-run by someone else (the actor of a re-run is the original one; the triggering actor is who pressed Re-run).
5. **Housekeeping that closes the rest:** every outside contributor's pull request waits for approval, every time; `CODEOWNERS` names the owner for everything, the workflows and `deploy/` in particular.

**Alternatives considered.** *Put the actor in the token's subject* (`include_claim_keys` with `actor_id`), so AWS itself says "only this account": the only way for AWS to tell the owner from another collaborator, because AWS evaluates only `aud` and `sub`. GitHub's documentation does not list `actor_id` among the keys a subject template accepts or say how it renders, and a template change alters every token the repository issues. Not built on an assumption; the Provision workflow now prints a real token's claims, which is the evidence needed to revisit it. *A second person as reviewer*: there is no second person; with one, "prevent self-review" must stay off or nobody could approve, so the reviewer is a pause, not a second pair of eyes (stated in the guide). *Enforce the rules for administrators on `main`, and require status checks*: with one maintainer and a required approving review, it would lock the owner out of their own pull requests; left to the owner, and reported by the script. *`sha_pinning_required` for every workflow*: touches the whole of CI for a risk that is about the two workflows holding a token; the spec holds those two. *A private repository*: removes strangers' pull requests altogether and is the simplest single lever; not chosen here because this repository is a public portfolio and demo.

**What it does not do.** AWS cannot tell the owner from anyone else who gets write access to the repository; if that ever happens, layers 3 and 4 and the script's access check are what stop them, so adding a collaborator must be a deliberate change to the script. The script assumes a repository owned by a person and refuses an organization's. **None of it has been exercised by a real run**: the guard, the trusts, the workflow and the script are pinned by specs and mutation-checked, the script ran against a stand-in GitHub and, once, against the real settings; whether an ID-based repository's *Environment* subject is spelled as inferred is shown by the first step of the first run, and a wrong guess is refused, not accepted.

## 73. A deployment smoke test is a fixed, throwaway environment that destroys itself, at the cheapest size that still has every kind of resource

The Terraform has never been applied. The request was a manual GitHub Actions run that deploys the AWS resources, tests them and destroys them, at the least possible cost. Reading what the stack costs and what a destroy leaves behind decided most of it:

- **Almost all of an idle dev stack's hourly cost is four lines**: the interface endpoints ($0.30, ten of them in each of three zones, more than the control plane and the NAT gateway together), the control plane ($0.10, or $0.60 on the repository's default Kubernetes 1.33, which entered extended support on 2026-07-29), the two `m7g.large` system nodes ($0.16) and Aurora's idle floor ($0.06): $1.19 an hour, from AWS's price list. The stack runs nothing on it, so most of that buys availability and private traffic that a one-hour test does not use.
- **The stack was already built to be destroyed outside prod**: buckets `force_destroy`, secrets with no recovery window, no final database snapshot, keys that wait seven days. So a throwaway environment can be created and removed repeatedly, with nothing colliding on the next run, except two things: the ECR repositories are named for the account (`task-api/<service>`), not the environment; and the CloudWatch add-on makes log groups at runtime that Terraform does not know.

**The decision.**

1. **A fourth environment, `smoke`, not `dev`.** Every name carries the environment, the state has its own key, and the role trusts its own GitHub Environment, so a destroy cannot touch another environment's resources. `create_ecr = false` keeps it off the shared repositories. The workflow is fixed to it: **no inputs**, the environment name written in the file, and a spec that forbids `inputs.` anywhere in it.
2. **A cheap profile, as data** (`envs/smoke.tfvars`), with two new variables whose defaults leave every other environment as it was (a Terraform test holds that): `vpc_interface_endpoints` (off: only the free S3 gateway endpoint) and `system_node_count` (one `t4g.medium`). Also two zones (the least EKS and Aurora take), a database capped at one unit, and a Kubernetes version in standard support. $0.26 an hour; a run is about an hour. Each saving is a thing the test then does not show, listed in the guide.
3. **Two jobs, not one.** `create` plans, checks the plan, applies, checks the stack and plans again; `destroy` has `if: always()` and `needs: create`, and runs on a fresh runner. One job with a final `always()` step loses the destroy when the job times out, the runner is lost or the job is cancelled; those are exactly the cases where a stack is half made.
4. **Nothing in settings can change what is built.** Not `TF_VARS_JSON` (which Provision AWS uses, and which wins over the committed variables): the stack's size and identity come from the committed profile and a variable file the workflow writes with `jq` and passes last (`environment`, region, no ECR, no second region, no deletion protection, plus the one thing that is yours, the hosted zone). The check of the saved plan then reads those values back from the plan, so a mistake in the workflow is caught before the first dollar. A zone name is validated as a plain domain name.
5. **The Kubernetes version is asked of EKS at run time**, not trusted from a calendar in code: the plan check refuses a version that is not `STANDARD_SUPPORT` today, because the repository's own default silently adds $0.50 an hour. It fails on an answer it cannot read, rather than going ahead.
6. **A destroy that does not give up, and does not clear what is not its own.** `terraform destroy` up to three times (a VPC fails to delete while a network interface is still being released); a lock is force-unlocked **only** when the create job did not finish, because then its terraform was killed and nobody else holds it, and only if the lock's id can be read; the add-on's log groups are removed after a successful destroy. Then a scan for what costs money or would stop the next run (cluster, database, load balancer, NAT gateways, instances, addresses, endpoints, VPCs, buckets, roles, aliases, log groups). **A call that fails is not an absence**: if the scan cannot look, it fails.
7. **What it checks** is that the infrastructure is there and works, with each claim made of a call to AWS: the control plane, nodes, add-ons and pods, the database, a KMS round trip that also proves the key refuses a request without the application's context, the bucket's encryption, the certificate, the queues, the secrets, the WAF, the KMS audit trail and the alarms; and a second `plan` that must find nothing to change. The script that does it is a file the specs run against stand-ins for `aws`, `kubectl` and `terraform`.

**Alternatives considered.** *Reuse `provision.yml` as a reusable workflow* for the apply and destroy legs: one copy of the logic, but several semantics I cannot test from here (environment variables and secrets in a called workflow, concurrency of the callee, approvals per call), in the first workflow that touches AWS. Instead the two shared steps (the owner check and the identity token) are copied and a spec requires them to be byte-identical to Provision's. *Run it in `dev`*: its destroy could remove a real dev stack. *A scheduled run*: not asked for; a nightly run is about $9 a month, plus whatever it leaves behind on a night it fails and nobody is looking. *An AWS budget alarm* as the safety net: a tag-filtered budget needs the tag activated for cost allocation and updates about once a day, which does not help against an hour. *A separate AWS account*: the best isolation and a setup the owner can choose; the profile does not need it. *Aurora scaled to zero*, *Spot* for the system node, *no KMS audit trail*: each saves cents and the third removes exactly the resources that have never been applied. *Keeping the stack up for debugging*: it is what costs the money; a failed run still destroys, and Terraform's error and the checks' lines are the evidence.

**What it does not do.** It does not deploy the application or prove the endpoints, the three-zone spread or Karpenter. It does not stop a person who cancels the run, or a runner that is lost, from leaving a stack: it reduces that to "run the workflow again" and makes the red run say so. The scan sees only the kinds of resource it lists. **None of it has run**: the specs prove the script's logic against answers I expect AWS to give, and the first real run is the test of that ([the guide](aws/smoke-test.md#not-verified)).


## 74. The local platform is proven by one scenario that runs unchanged on Docker Compose and on kind, and the first run is allowed to find faults

`docker-compose.yml`, `deploy/local/up.sh` and the kind configuration were written in roadmap 2 without a Docker daemon on the authoring machine, and every roadmap since said "Compose and `kind` have not been run". CI builds the four images and renders the chart; it never starts either. Running them was the whole task, and the first thing it needed was a definition of "works" that does not depend on who is looking.

**The decision.**

1. **"Works" is one script, `deploy/local/verify.sh`, that uses the platform as a client would**: only the address a client has (the gateway, or the Ingress), no `docker exec`, no `kubectl exec`. It makes two accounts, signs in, writes a project and a task, and follows the two event paths that cross every service (an assignment: API, outbox, worker, SNS, SQS, Notification service, SMTP; a password reset: Auth service to the same mailbox), then uses the link in the email. It reads the caught mail from Mailpit, which is the only thing a person at a keyboard would have to look at.
2. **The same script for both stacks, so the two are comparable.** It asks only for paths that nginx in Compose and the Ingress on kind (like the ALB) both route; its first draft asked for `/readyz` and `/livez`, which the Ingress rightly does not publish. It waits for the API and for the Auth service separately, because each starts on its own.
3. **A check must be able to fail, so each component was stopped in turn** and the failing checks recorded ([the guide](local-platform.md#what-verifyshproves)). Stopping `ai` fails one check; `worker`, one (the email, not the inbox); `notifications` and the AWS mock, the three email checks. Those results say what each check actually exercises.
4. **A fault found on the way is fixed where it is, with a test that fails without the fix.** Nine were found ([the list](local-platform.md#what-the-first-run-found)). 37 deliberate breakages of the fixes (the Compose file, `up.sh`, the kind configuration, the chart template, the SMTP rule, the crash logging, `database.yml`) each fail a test.
5. **Fixes keep the production meaning.** `seeds: false` is set for the production primary only; the guard in `db/seeds.rb` stays, so a hand-run `db:seed` in production still aborts. The SMTP rule signs in whenever a user name is given, exactly as before. The chart's other releases render unchanged (25 renders compared, 279 resources valid).
6. **The kind Ingress manifest is pinned to a controller version and to the kind build** instead of following a page on kind.sigs.k8s.io, whose content changed under the script. The cost: the Kubernetes project retired ingress-nginx in March 2026 (its repository is read-only; [announcement](https://www.kubernetes.io/blog/2026/01/29/ingress-nginx-statement/)), so a pin never gets a fix ([ADR 77](#77-the-local-platforms-leftovers-every-service-traces-its-requests-the-dashboards-rules-ship-to-compose-a-lost-reset-email-is-logged-one-smtp-rule-and-traefik-for-ingress-nginx) replaced it with Traefik). The chart's `className: nginx` is used only locally, so replacing the controller is this one URL and a class name; the committee points to Gateway API or another Ingress controller, and none is a drop-in.

**Alternatives considered.** *Add a CI job that starts Compose and runs the script.* It would catch this whole class of fault for good, and it is the next thing to do, but I could not try a GitHub runner here, the images take minutes to build, and a job I have not seen pass would be the first thing to flake; it is on the Next list with that reason. (Built afterwards: [ADR 75](#75-the-platform-job-runs-in-ci-on-credentials-that-belong-to-nobody-builds-the-images-once-for-both-stacks-and-says-what-the-platform-said-when-it-fails).) *Test the faults only with specs that read the files.* Done as well, because they are cheap and they hold the fixes, but they would not have found any of the nine: the faults were in how the parts meet. *Raise a unit test for `verify.sh`.* Its value is in running against a real stack; a stand-in for `curl` would test the stand-in.

**What it does not do.** It is one machine (Apple silicon, Docker Desktop with the containerd image store, Helm 4, Kubernetes v1.37.0): fault 1 and the Helm 4 behaviour in fault 7 are reproduced only there. It is not production: one replica, no autoscaling, policies or External Secrets, no KMS, SES or Bedrock. It was not run in CI (it is since: [ADR 75](#75-the-platform-job-runs-in-ci-on-credentials-that-belong-to-nobody-builds-the-images-once-for-both-stacks-and-says-what-the-platform-said-when-it-fails)). Three things it noticed are left open (the AI service's spans missing from Jaeger, three empty dashboard queries on Compose, a reset request that answers 202 when the event bus is down), listed in the guide.

## 75. The platform job runs in CI on credentials that belong to nobody, builds the images once for both stacks, and says what the platform said when it fails

ADR 74 proved the local platform by hand and left the CI job on the Next list, for three reasons: a GitHub runner was not available to try it on, the images take minutes to build, and a job nobody has seen pass is the first thing to flake. All nine faults it found had passed every job in CI, because none of them starts anything. Leaving it out means the next fault of that kind is found the same way, by a person, after the merge.

**The decision.**

1. **A `Platform` job in `ci.yml`, run once per stack (a matrix of `compose` and `kind`), on every pull request and on every push to `main`.** It is in `ci.yml` and not in a workflow of its own because the Deploy workflow runs only after CI succeeds on `main`: a commit that does not bring the stack up is not built and pushed. The stacks run on separate runners (`fail-fast: false`, so one failing does not hide the other's result), with a 30-minute limit, `permissions: contents: read`, no environment and no secret.
2. **The credentials are made on the runner and belong to nobody.** The images need Rails credentials (`secret_key_base` and the three Active Record encryption keys), and the owner's `config/master.key` opens only the committed file. A pull request from a fork gets no secrets, and putting the real key in a repository secret would make the production key an input to every CI run. `deploy/local/throwaway_credentials.rb` writes `config/credentials/production.yml.enc`, which Rails reads in place of `config/credentials.yml.enc` when `RAILS_ENV=production`, and prints its key. The job masks the key and exports it as `RAILS_MASTER_KEY`; the committed file is untouched. The script refuses to run where `config/master.key` exists (the owner's machine, where the file could end up in a real deploy) and where its output exists already. `.dockerignore` keeps `config/credentials/*.key` out of images and lets the `.yml.enc` in, which is how the image carries it; the job checks that it did.
3. **The images are built once, from this checkout, for both stacks.** `docker/bake-action` reads `docker-compose.yml`, builds the four services that have a build section, and loads them into the runner's Docker. `source: .` is not optional: the action's default is a fresh clone of the repository, which does not hold the credentials the job just made. Layers are read from the cache the `images` job fills, under the same names (read only, so the two jobs do not overwrite each other's). Compose starts with `--no-build`; `up.sh` takes `SKIP_BUILD=1` and loads what is there.
4. **`up.sh` takes the key from `RAILS_MASTER_KEY`**, and from `config/master.key` when that is unset. Nothing else about it changed.
5. **kind is installed at a pinned version** (v0.33.0, the one the guide was measured with) and Helm by the action CI already uses; their versions are printed in the log.
6. **When the job fails it says what the platform said**: `deploy/local/diagnose.sh` prints the state of every container or pod and the tail of each log, because the runner is gone by the time anyone can ask it a question. It is also what to run by hand after a failed `verify.sh`.
7. **The job's structure and the scripts it calls are specified without a runner.** `spec/deploy/platform_ci_spec.rb` (36 examples) holds the order of the steps, what the job may not use, and runs `up.sh`, `diagnose.sh` and the credentials script against stand-ins for docker, kind, kubectl and Helm. 61 deliberate breakages (the job's steps and conditions, `up.sh`, `diagnose.sh`, the credentials script, `.dockerignore`) each fail a spec; the first passes left three survivors, all gaps in the spec, which are closed, and a last pass killed all 61.

**Alternatives considered.** *A workflow of its own.* It would keep a new, unseen job out of CI's way and could be scheduled, but it would not gate Deploy, and a check that does not gate anything is the one people stop reading. *The real master key as a repository secret.* It would test the real credentials file, and put the production key in reach of every workflow run, for a stack that only needs a key that opens a file. *Replacing `config/credentials.yml.enc` in the workspace.* It works, but it modifies a tracked file where a deploy from the same tree would ship it; a new file beside it is loud only when someone looks, and the script refuses where the real key is. *Compose only.* Compose does not touch the chart: four of the nine faults (the Ingress node, the duplicated variable, the missing key source, the span-export errors) were found only on kind. *One job running Compose and then kind.* It would build once, but a failure in the first would hide the second, and in series the two would take the sum of their times. *A nightly schedule instead of every pull request.* The nightly would find the fault the morning after it merged. *A self-hosted runner.* A host to patch for a job that fits a hosted one.

**What it did on a runner, and what it does not do.** It passed on its first run and on the second, with no retry: both stacks, 25 of 25 checks ([the numbers](local-platform.md#in-ci)). The first run was on Linux on amd64 with Docker Engine 29.4.2 (the containerd image store, the same as the Mac that found fault 1), kind v0.33.0, kubectl v1.37.1 and Helm v4.3.1 (`azure/setup-helm` installs the latest release, so the "CI uses Helm 3" of the first version of the guide was wrong). Point 3 assumed the `images` job's cache would be read. On the first run it was not: `docker/bake-action` does give BuildKit the token (the four manifests were imported), but no step was reused, in these jobs or in the `images` job beside them, and the repository's Actions cache was at its 10 GB limit, which probably evicted what `main` had written (an inference, not checked). On the second run ([run 41548017817](https://github.com/AravindRajeshkanna/rails-task-api/actions/runs/41548017817)) it was: 40 and 39 steps reused, the images in about 1 min 40 s instead of 4 min, both stacks 25 of 25 again. So a pull request's first run pays for the build and later runs do not; the decision to read the cache and not write it stands. Not tested: the failure path (`diagnose.sh` has not run on a runner), the disk after kind has loaded its images (it fitted in 81 GB free), the classic image store, and any run but those two. It was not a required check on `main` when this was written; [ADR 76](#76-the-platform-jobs-are-watched-then-required-helm-is-pinned-and-the-settings-script-owns-mains-required-checks) pins Helm and gives the settings script the list of checks to require. It builds the images three times per pull request (the `images` job, and each stack's job), which costs nothing on a public repository and is a few minutes of wall-clock time. It proves what `verify.sh` proves and no more: not production (one replica, no autoscaling, policies, External Secrets, KMS, SES or Bedrock), not the observability profile, and the negative controls of ADR 74 stay manual.

## 76. The Platform jobs are watched, then required; Helm is pinned; and the settings script owns main's required checks

Next item 17 asked for four things in an order: watch the `Platform` jobs on a runner, fix a failure at its cause and not with a retry, pin Helm, and require the jobs on `main` once a few runs are clean. The runs were read before anything was changed.

**What the runs showed.** Every CI run from the first `Platform` run (2026-11-02) to this change (2026-11-06): 36 runs, 24 on pull requests and 12 on pushes to `main`, 20 of them Dependabot's, every one a first attempt.

- **The `Platform` jobs: 72 runs (36 per stack), 72 passed, 25 of 25 checks each.** Nothing was retried, and no failure came from the jobs' own cause.
- **Time:** Compose median 3.5 min (fastest 2.8, 90th percentile 5.3, slowest 11.9); kind median 5.9 (4.5, 7.3, 8.3). The slowest Compose job was one of ten Dependabot runs started within three minutes: its image build took 482 s (a bumped lockfile rebuilds the `bundle install` layer whatever the cache holds) and `docker compose up` took 153 s, against about 28 s. The 30-minute limit is 2.5 times the slowest run.
- **What varied between runs:** BuildKit v0.33.1 to v0.34.2 (the buildx action brings its own); kubectl client v1.37.1 to v1.37.2 (13 and 23 of the 36 kind jobs), over the days the runner image moved from 20261025.179.1 to 20261101.186.1. **What did not:** Docker Engine 29.4.2 on the containerd image store, Compose v5.1.3, Ubuntu 26.04, kind v0.33.0, the node image v1.37.0, Helm v4.3.1 (the latest release all week), and 81 to 83 GB of free disk before the build.
- **The layer cache:** no step reused in 9 of 72 jobs (the first run of a pull request, and seven jobs on pushes to `main`), 15 in 4 (the Rails update, whose lockfile rebuilds the install layer), 21 to 42 in the other 59.
- **The other jobs in the same runs:** `scan_ruby` failed in 30 (the Rails advisories published on 2026-11-04, fixed by #36), `test` failed in 1.

**The decision.**

1. **Helm is pinned to v4.3.1, in one place.** `HELM_VERSION` is a workflow-level `env` in `ci.yml`, and both jobs that install Helm (the chart checks in `infrastructure`, and `Platform (kind)`) read it. `azure/setup-helm` with no version installs the latest release, so Helm 4.4 or 5 would have changed the chart checks and the kind platform on the day it came out, with no commit to blame. 4.3.1 is the release all 36 runs used. Dependabot does not see a version in a `with:` block, so a bump is a pull request, and `Platform (kind)` plus the chart checks are its test. `spec/deploy/platform_ci_spec.rb` holds it: an exact `vX.Y.Z`, the one source, the two jobs and no others, and no second workflow that installs Helm.
2. **kubectl, Docker, Compose and BuildKit are not pinned, and the log says which they were.** They are the runner image's (kubectl, Docker, Compose) and the buildx action's (BuildKit); the job prints their versions. Pinning kubectl would add an action to keep current for a tool whose commands here (`get`, `rollout`, `port-forward`, `logs`) have not changed across a minor release, and it moved one patch release in the sample without a failure. Pin one the day a run shows it mattered.
3. **The settings script owns main's required checks.** `deploy/scripts/github_settings.rb` has `REQUIRED_CHECKS`, the two job names GitHub shows (`Platform (compose)`, `Platform (kind)`); it reports whether `main` requires them, and `--apply` adds the missing ones through `PATCH /branches/main/protection/required_status_checks`, the endpoint that changes nothing else about `main`'s protection. It keeps every check `main` already requires (with the app each must come from) and whether branches must be up to date, and it sends no app for the new ones, so GitHub binds each to the app that has been reporting it (GitHub Actions). Where `main` has no status-check rule at all, the finding stays open: creating the rule means writing all of `main`'s protection, which this script does not do. A spec reads the names against `ci.yml`, because a check no job reports would hold every merge for ever.
4. **A flaky spec the runs turned up was fixed at its cause.** `load_handling_spec` failed once in 36 runs ("starts afresh in the next window", 201 where 429 was expected). The organization budget, and Rack::Attack's budget for the expensive endpoints, count in windows that turn over on the wall clock every five minutes (`now.to_i / 300`), and that run's suite spanned 02:55:00. An example that spends a budget in real time is given a fresh one if the clock crosses a boundary in the middle of it; the example that sends 121 requests is exposed far more than the one that failed. Every example in the two groups now starts in the middle of a window with the clock held still; the two about the boundary move it themselves.
5. **Nothing was retried or marked as allowed to fail.**

**Alternatives considered.** *Require every job in `ci.yml`.* It is the better rule: on 2026-11-06 ten pushes to `main` in a row were red, the Dependabot bumps merged with their own pull-request runs red, because nothing required `scan_ruby`. It is also a decision about what blocks a merge for a job that can go red with no commit behind it (an advisory published overnight), so the list is one constant and the owner extends it, not this change. *Enforce the rules for administrators.* It is what would stop the owner: with `enforce_admins` off (and this script leaves it off), GitHub shows a required check as unmet and offers the administrator a bypass, which is the footing the one required review is already on. Roadmap 8 left it alone because with one maintainer it would lock the owner out of their own pull requests, and that still holds. *Retry a failed `Platform` job.* It would hide the flake the 36 runs are the evidence against. *Pin kubectl with `azure/setup-kubectl`* (above). *Read Helm's version from a file Dependabot understands.* `setup-helm` takes it only as an input.

**What it does not do.** **Nothing here was applied to GitHub.** The script's read-only check ran against the real repository and reports `DIFF access: main requires these checks before a merge: wanted ["Platform (compose)", "Platform (kind)"], found []`; the shape it read (`required_status_checks` with `strict: false` and empty `contexts` and `checks`) is what the spec's stand-in GitHub renders. The `PATCH` has not been sent: the spec holds its body against GitHub's documented endpoint, and whether GitHub accepts `checks` without an `app_id` is known only when it is applied (the script stops with GitHub's own error if it does not). **The next `--apply`, including the one in the smoke-test setup, will also add the two checks to `main`;** it adds nothing else to `main`. With administrators not enforced, the effect for the owner is that a red `Platform` job is flagged as an unmet requirement on every pull request, not that a merge is refused. 72 jobs from 36 runs in four days are a sample of one runner image family, one week and one dependency churn; they do not say what a Docker or Helm release will do, which is what the pin and the printed versions are for. The failure path (`diagnose.sh`) has still not run on a runner. The flaky spec's cause is shown by a clock run fast, and by the suite's window arithmetic; the CI failure itself is consistent with it (its suite spanned a boundary) and cannot be proved to have been it.

## 77. The local platform's leftovers: every service traces its requests, the dashboard's rules ship to Compose, a lost reset email is logged, one SMTP rule, and Traefik for ingress-nginx

Next item 16 listed five things [local-platform.md](local-platform.md#found-and-not-fixed) had left open, two of them as questions ("why", "whether"). Each was measured on a running stack before anything was changed, and two of the answers were not the ones the list implied.

**1. "The AI service's spans never reach Jaeger" was every service's request spans.** The AI service sent nothing because it has no database: all that Auth, the Notification service and the API had ever exported were their PostgreSQL and HTTP-client spans, and a service with neither had nothing to send. Measured on Compose: 0 spans of kind `server` in Jaeger from any service, `trace_id` on 0 of the access-log lines (the runbook's step "take a `trace_id` from a failing log line" could not be followed), and no tracer in any middleware stack. The cause: the setup used the Rack and "Rails" instrumentations and neither adds the Rack middleware to a Rails application. That is the ActionPack instrumentation's Railtie; the "Rails" entry is a shortcut whose own initializer is skipped when it is required from an initializer, as it was. Each library logged "successfully installed", which is what made it look configured.
   - **The fix** is one module, `ServiceKit::Tracing`, that the three services' Railtie and the Task API's initializer both call (they had two copies of the setup, which is how both came to carry the fault). It uses the ActionPack instrumentation, which also names the span for its route (`GET /api/v1/projects/:id`). Measured after: server spans from the API (9 operations), Auth (5) and the AI service (2); `trace_id` on every access-log line (10 of 10, 3 of 3, 11 of 11); and one trace of 37 spans from the API's `POST /api/v1/ai/suggest_priority` through its two client calls to the AI service's server spans.
   - **Held by** `gems/service_kit/spec/tracing_spec.rb` (13 examples) and `spec/initializers/opentelemetry_spec.rb` (3), which boot a small Rails application (the Task API itself, for the second) in a child process in development, send it a request and read the spans back from an in-memory exporter: one server span per request and one tracer in the stack, the route as its name, the caller's trace continued from `traceparent` and from the load balancer's `X-Amzn-Trace-Id`, the caller's sampling decision followed, X-Ray-valid trace ids, the trace passed on to a service it calls, `/up` and `/metrics` untraced, the service name, and off without an endpoint (unset, and empty as Compose passes it), in the test environment and under `OTEL_SDK_DISABLED`.
   - **Not fixed:** the Notification service's work is an SQS consumer, so it has no server span and its trace is its own database spans; the AWS SDK instrumentation does not carry the trace through SNS and SQS (`inject_messaging_context` is off), so an event's journey is not one trace.
   - The architecture page listed ActiveRecord among the instrumentations; it was never installed (the PG instrumentation produces the database spans). It now lists what is.

**2. The dashboard.** Twenty queries were run against Compose's Prometheus. Two were empty because Compose's Prometheus loaded no rules; `deploy/scripts/render_local_rules.rb` now writes the groups of both PrometheusRule files (40 rules, recording rules and alerts) to `deploy/docker/prometheus-rules-local.yml`, which Compose mounts, and a spec fails when the committed file is not what the script prints. All 40 evaluated healthy. The third, `taskapi_queue_ready_jobs`, is **not a Compose fault**: the collector creates a series for a queue only while a job is ready in it, so a quiet stack has none; it was present (one series, `solid_queue_recurring`) once a recurring job had been ready. A **real fault turned up in the process**, in Kubernetes as much as Compose: `taskapi:http_error_ratio:rate5m` divided a sum of 5xx responses by the total, and with no 5xx there is no series to sum, so a healthy system read "No data". It is now `(sum(...5xx) or vector(0)) / clamp_min(...)`: 0 while requests succeed, still nothing when nothing is scraped. `recording-tests.yaml` (5 `promtool` tests, now a CI step) holds it; the old rule fails the first, and so does dropping the `clamp_min`.

**3. A password-reset event is not retried when the bus returns, and the failure left no trace.** Measured on Compose by disconnecting the AWS mock from the network (pausing it was misleading: the SDK's three attempts waited in its socket and were served on resume, so the mail seemed to arrive late). Unreachable: the request answered 202 in 1.1 s, nothing in the Auth log, and 60 s after the mock came back no mail; asking again delivered one. Hanging instead of refusing, the same request takes about 16 s (3 attempts of 3 s to connect and 5 s to read) while holding a Puma thread. The 202 is deliberate (the endpoint must not reveal who has an account) and "the user can ask again" is the design, so **nothing is retried and no outbox was added** to the Auth service: that is a table, a relay and a job for a request the user repeats in a minute. What was a gap is that nothing subscribes to `Rails.error` in the services, so the handled error went nowhere (fault 5 of [roadmap 10](roadmap.md#roadmap-10-running-docker-compose-and-kind-for-the-first-time) had the same shape). `AuthService::Events` now logs `auth.event_publish_failed` with the event type and the error, never the address or the link; two examples hold it (a service error and an unreachable topic), and a mutant that logs the event's data instead is caught.

**4. The Task API's production SMTP block signed in whatever the relay offered**, as the Notification service's did until [roadmap 10](roadmap.md#roadmap-10-running-docker-compose-and-kind-for-the-first-time). It now calls `ServiceKit::SmtpSettings.from_env`, passing the login it keeps in its credentials as a second argument (which wins over `SMTP_USERNAME`), and signs in only when there is a user name. The first version made it a keyword; Ruby then read the Notification service's braceless `from_env("SMTP_ADDRESS" => ...)` as keywords and its spec failed, so it is positional, and an example holds a bare hash. A spec delivers a real message through the settings production builds to a relay with no login. The helper's timeouts (5 s to connect, 10 s to read) now apply to the Task API's mail. **Not run:** the Task API's mailers on a stack; neither platform sends mail through it, and `production.rb` itself is read by a spec, not executed.

**5. ingress-nginx is replaced on kind by Traefik, v3.7.16 (chart 42.1.3).** The Kubernetes project retired ingress-nginx in March 2026 (no releases, bug fixes or security updates), and the thing that proves the platform works should not sit behind a controller that can no longer be patched.
   - **Why Traefik.** The chart's Ingress template is shared with the ALB, and what the local controller has to do is route path prefixes from an Ingress with no host and no annotations. Any controller that does that works; the choice is the smallest change that does. Traefik installs from a versioned chart in an OCI registry (`oci://ghcr.io/traefik/helm/traefik`, pinned in `up.sh` like every other version here, and nothing like the page that changed under the script before), runs non-root, and reads plain Ingress objects. **No other controller was tried.**
   - **How.** `deploy/local/traefik-values.yaml`: the controller on the control-plane node (kind forwards `localhost:8080` to that node's port 80 only) on `hostPort: 80`; `--skip-crds` and the CRD provider off, since nothing here uses an IngressRoute; no Service; its own IngressClass, `traefik`, named once in `values-local.yaml`. **A trap found by running it:** the chart's default rolling update starts a second pod beside the first, which waits for ever on the port, so the first `helm upgrade` that changed the pod template hung (the earlier "repeatable" check passed only because nothing had changed). It now stops the old pod first (`maxSurge: 0`), and two real rollouts were run through. The log is colourless, for `diagnose.sh` to put in a CI log.
   - **Measured:** `up.sh` on a fresh kind cluster, then `verify.sh`: **25 of 25 checks**, the same as on Compose; with Traefik scaled to zero the same script fails at the first check, so the checks do go through it; the controller's pod on the control-plane node, no CRDs installed, no errors in its log.
   - **On a runner:** this pull request's two CI runs both passed `Platform (kind)` (7 min 52 s, then 5 min 20 s, 25 of 25 each; the log shows the chart pulled from ghcr.io and `docker.io/traefik:v3.7.16` deployed) and `Platform (compose)` (25 of 25). Two runs are not a sample: the roadmap 12 watch applies to this controller from here.
   - **Not verified:** WebSocket upgrades through it (the API answers `/cable` with its own 404 to this request with or without the Ingress, so the path was not exercised); that the Ingress's `ADDRESS` is empty now, where ingress-nginx wrote `localhost` (nothing reads it).
   - *Gateway API*, which the Kubernetes project recommends, was not chosen: the chart would need a second route template for the local controller alone, because the cloud's ALB reads Ingress, and the local platform's job is to run the cloud's chart.

**6. The Notification service restarts on a crash in Compose** (`restart: on-failure`). Its consumer ends the process when it crashes, on purpose, and expects an orchestrator to start it again; Kubernetes does, Compose did not, so a transient fault left the stack without email and with the crash only in the log. Verified by killing Puma inside the container (a `docker kill` counts as a manual stop and does not restart): one restart, healthy again, and `verify.sh` 25 of 25 after. **The cost:** a crash that repeats is now hidden from the `Platform (compose)` job, which passes once the container is back; the `notification.consumer_crashed` line in the log and `diagnose.sh` are where it shows.

## 78. Secret scanning in CI, a webhook secret replaced in two steps with both signatures in between, and no secret in an idempotency record

Next item 6 named the two open items of the threat model that cost the least: no secret scanning in CI (T20) and no rotation of a webhook's signing secret with an overlap (T18). The audit before building either found that one was half done, and found a third thing under the second.

**1. Secret scanning.** GitHub's own secret scanning and push protection were already **on** (roadmap 8's audit says so; read again with `GET /repos/...`: both `enabled`). That is a setting, so nothing in the repository recorded it and nothing would have noticed it being turned off. What was missing is the part GitHub's feature is not: a check that fails a pull request, on files and formats of this project's own, over every commit.
   - **The history, by hand, before any tool.** 38 commits (before this pull request's own four), 1.4 MiB. `git grep` across all of them for private-key headers, AWS, GitHub, Slack, OpenAI, Anthropic and Google token shapes, Slack webhook URLs and JWTs: **no match**. The same invocation finds a string that exists (`SecureRandom.hex`: 37 hits in `webhook.rb` alone), so the empty answer is not a broken command. Files ever added that look like secrets: `.env.example` and six `.tfvars` (configuration, no credentials). This is not a gitleaks run: see "not verified".
   - **The tool: gitleaks, as a release binary.** Alternatives: *TruffleHog* verifies what it finds by calling the provider with the secret, which is the wrong thing for a public repository's CI to do with a candidate secret, and it is AGPL; *detect-secrets* works from a baseline file that someone has to keep, which fits a repository that already has secrets better than one that has none; *gitleaks-action* is a third-party action that gets the job's token and asks for a licence key from organizations; *GitHub's feature alone* is on and cannot be given this project's rules or fail a pull request. The binary is pinned by version **and by the SHA-256 of the archive, written in the workflow** (taken from the release's checksums file): a download that differs is refused, not run. The hash proves the file is the one that was written down, not that the release is honest. Moving it is a pull request; Dependabot does not see it.
   - **What it reads.** Every commit (`fetch-depth: 0`), because a secret a later commit deleted is still in the history, and the history is public. Findings are printed `--redact`ed, because the log of a public repository is public too. The job uses no secret, has `contents: read`, leaves no token in the checkout, and cannot fail without failing the job (a spec bans `|| true`, `--exit-code 0` and `continue-on-error`).
   - **The config** (`.gitleaks.toml`): gitleaks' default rules, plus three that match on a *path*: a Rails master key or credentials key, Terraform state, a real `.env`. `.gitignore` already excludes all three; a rule is for the day one is forced in. They are checked against paths that only look like them (`.env.example`, `production.yml.enc`, `*.tfvars`, `docs/env.md`) and against every tracked file (none matches). **One allowlist entry, added by the next pull request's first run** ([ADR 79](#79-erasing-a-person-across-services-the-outbox-tells-the-auth-and-notification-services-the-tombstone-keeps-the-subject-and-jwt-mode-asks-the-auth-service-for-the-password)): five specs gave a made-up UUID to `auth_subject`, and the default `generic-api-key` rule reads the name (it contains "auth") and the value's entropy. The exception is one rule, a spec directory and a UUID-shaped value for that one name, all three at once, and the control step now also plants the same line outside a spec and a cloud key inside one, which must still be found. Rewriting the fixtures would not have helped: the scan reads every commit, and a squash-merge makes the same lines a new commit. **No content rule for this application's own variable names** (`SECRET_KEY_BASE`, `METRICS_TOKEN`, ...): run over the tree it would flag 11 lines that are deliberately fake local-development values (`.env.example`, `docker-compose.yml`, `up.sh`, `diagnose.sh`), and a rule whose first act is an allowlist of the places it is used teaches people to ignore it.
   - **A scan that finds nothing proves nothing until the scanner is known to find something.** Before the real scan, the job makes a throwaway repository outside the checkout, plants an AWS access key (put together from two pieces, so the workflow file does not contain it) and a `config/master.key`, and runs the same binary with the same config: it must exit non-zero and report both rules (`jq` reads the report). A config that matched nothing, or an allowlist that swallowed everything, fails the job instead of passing every run.
   - **GitHub's side is now checked.** `github_settings.rb` reads `security_and_analysis` and wants secret scanning and push protection `enabled`; `--apply` turns on the one that is off with a `PATCH` that names only that feature. Where GitHub does not say (a token that is not an admin's is told nothing) the finding stays open with no fix. Run read-only against the repository: both `ok`.
   - **Not a required check.** `Secret scan` is the name it would carry; whether `main` requires it is Next item 17's decision with the others.
   - **On a runner (this pull request's first CI run):** the archive's hash matched (`...tar.gz: OK`); the control repository was scanned (1 commit) and **2 leaks were found**, and the `jq` check confirmed they were the AWS key and the `master.key`; the real scan read **41 commits (3.31 MB) in 551 ms and found nothing**. So the default rules do **not** flag the deliberately fake local values (`local-development-only-secret-key-base-...` and the others), no allowlist was needed, and the job passed in 6 seconds on its first run. All 15 jobs of the run passed, including both `Platform` jobs.
   - **Not verified:** **gitleaks did not run on my machine.** The environment refused to execute the downloaded binary (it is code from outside the repository, and I did not work around that), so the first run of the config is the runner's, and it is one run: not a sample, and it says nothing about what a future gitleaks release or a future commit will flag. The pinned hash proves the file is the one written down, not that the release is honest. The rules find what has a known format or file name: a password in a sentence, or a token in a format neither gitleaks nor GitHub knows, passes.

**2. A webhook's signing secret is replaced in two steps, with both signatures in between.**
   - **The contract.** `POST /webhooks/:id/rotate_secret` makes a new secret and returns it once, as `next_secret`. From then on every delivery carries **two** signatures: `X-TaskApi-Signature`, made with the *current* secret exactly as before, and `X-TaskApi-Signature-Next`, made with the new one. `POST /webhooks/:id/promote_secret` makes the new secret the secret (one signature again, the old one signs nothing); `POST /webhooks/:id/cancel_rotation` forgets the new one. Project admins only (a member or an outsider gets 404 by id, like every webhook route), `409 no_rotation_in_progress` for promoting or cancelling when nothing is waiting, 20 rotations an hour per person.
   - **Why two steps, and why the old secret stays first.** The usual way (Stripe's) makes the new secret the signing one at once and keeps the old valid for a while. For a receiver that is a chicken-and-egg: it cannot hold the new secret until the rotation has happened, and from that moment its single check of the header it has always read fails. Here the header a receiver already reads keeps the old secret until the admin promotes, so **a receiver that does nothing keeps working** through the whole overlap, one that has the new secret can check the second header before anything depends on it, and the moment of the switch is the admin's, after the receiver is ready, not the sender's. The price: the old secret is still the one signing until promoted, so for a leak the procedure is rotate, give the receiver the new secret, promote at once.
   - **Alternatives:** delete and recreate (today's way; a new id, the delivery log gone, and the receiver must switch in the same instant); one header with both signatures in it (`sha256=a,sha256=b`: a receiver that compares the header as a whole fails the day it is first sent, and the documented contract was a single value); a time-limited overlap that ends by itself (a receiver that has not switched fails with no one having done anything, and the overlap's end is the one thing that must not be a surprise). A rotation left half done therefore signs with the old secret for ever: the cost of not ending it by itself, written in the runbook with the query that finds them.
   - **Storage.** `webhooks.next_secret` (text) is encrypted exactly as `secret` is, with a data key of its own that KMS wraps, and is picked up by `kms:status`, `kms:encrypt` and `kms:verify` (the guards that list every encrypted attribute were updated on purpose: a new one is a decision). `webhooks.rotation_started_at` is a plain column and the one the API reads: `rotating` is true when it is set, so listing webhooks decrypts nothing (a spec holds the KMS request count at zero; reading `next_secret` to answer would have cost a `Decrypt` per row). A check constraint says the two are set together or not at all, added `NOT VALID` and validated in the next migration, as the repository does.
   - **Beginning again replaces the new secret.** It has never signed alone, so no receiver depends on it, and it is how a new secret that was lost (it is shown once) is made again. Because of that the endpoint is **not idempotent** on purpose: a retry after a lost answer needs no key, and nothing keeps a copy of the secret (next section). Promoting and cancelling lock the row and answer 409 to the second of two admins who press together.
   - **Signed at the attempt, not at the enqueue.** The deliverer signs every attempt with what is current then, so a retry that was waiting when the admin promoted carries the new secret. A receiver that has not switched refuses those, and the job retries for about an hour before they stay failed in the log.
   - **Cost.** One `GenerateDataKey` to begin, one `Decrypt` and one `GenerateDataKey` to promote, and while a rotation is open one more key to unwrap per webhook per pod per five minutes and a second HMAC per delivery (microseconds). Under a KMS outage beginning and promoting answer `503 encryption_unavailable` and change nothing; a delivery waits and retries as it already did.
   - **Events, not the audit trail.** Each step emits `webhook.secret_rotation_started`, `_promoted` or `_cancelled` with the webhook, the project and the person, and never a secret (a spec compares the payload keys and searches for the secret). Webhooks are not `Auditable` at all today (creating one, changing its URL or deleting it leave no trail either); adding the concern as it is would write each change's `saved_changes`, which for these columns is ciphertext, permanently. That is its own piece of work.
   - **Held by** `webhook_spec` (rotation: 8 examples, including the database refusing a half-made rotation and two admins promoting together), `deliverer_spec` (5: the two headers each verify only with their own secret, before, during, after promoting and after cancelling, and a retry after the promotion carries the new secret), `webhooks_spec` (15 for the rotation, 1 for the idempotency record: the walk-through a receiver sees, who may and that the policy is asked, 409, 503, the limit and that it counts each person apart, events, no KMS request to list), the policy and tenant-isolation matrix (the route guard fails until a new route has a decision), and the rswag spec (the 3 endpoints in the OpenAPI document). `idempotency_spec` +2, `encryption_spec` +1, `github_settings_spec` +4, `secret_scan_spec` 19.
   - **Not verified:** against real KMS (the specs use the test client the other encrypted columns use; promoting holds a row lock across two KMS calls, which a slow KMS would lengthen); a real receiver other than the specs' own HMAC; a rotation under load; that the second header passes unmodified through every proxy a customer has (it is an ordinary header).

**3. The first answer to `POST /webhooks` was kept, secret and all, for a day.** Found while checking that "shown once and stored encrypted" is true: the action is `idempotent :create`, the concern stores the response body in `idempotency_keys.response_body` (plain text, 24 hours), and the body of that response is the only place the signing secret is ever in the clear. **Measured:** with an `Idempotency-Key`, `idempotency_keys.response_body` contained the secret (a probe spec printed `true`). ADR 55 had said the opposite as a principle (responses that hold a credential "must not sit in a table") and applied it to sign-in, registration and password reset, but not to this.
   - **The fix** keeps the idempotency and drops the secret: `idempotent :create, redact: :secret` stores the answer with `data.secret` removed, so a retry gets the same webhook (no second webhook delivering every event twice) without it. An answer whose shape the redaction cannot find (no `data` hash) raises and rolls the write back, rather than keep what it could not remove. A client that lost the first answer has no secret to read back and does what any client does that lost it: rotates. No other idempotent action returns a credential (checked: every resource's attributes were read).
   - **Alternatives:** leave webhooks out of idempotency like sign-in (a retried create then makes a duplicate that delivers every event twice, which is what the keys were added to prevent); encrypt `response_body` for everyone (a KMS request for every stored answer, to protect one).
   - **Consequences:** a replay of a webhook creation no longer includes `secret` (CHANGELOG, OpenAPI description). **Rows written before this change may still hold a secret until the daily purge removes them** (24 hours after the request, purged at 04:10); an operator who wants them gone sooner can delete `idempotency_keys` where the path was a webhook creation, and nothing else depends on them.

**What this does not do.** It does not make the scan required of a pull request, rotate anything automatically, end a half-finished rotation, put webhooks in the audit trail, or tell a receiver to stop accepting the old secret (it cannot).

**Verification.** Full suite **1,840 examples, 0 failures** as CI runs it (93.64% line, 83.08% branch; floors 92 and 81), RuboCop (654 files) and Brakeman clean, the OpenAPI document regenerated. The mutation check killed 62 of 62 after two gaps in the specs were closed. The settings script, run read-only against the repository, reports both scanning features `ok`. **One unrelated spec was fragile and is fixed here:** `organization_audit_events_spec` compared an Organization's id with the ids of events of any type, and failed in the full run once the id sequences had moved (a Membership or Project id equalled it); it now compares the type with the id.

## 79. Erasing a person across services: the outbox tells the Auth and Notification services, the tombstone keeps the subject, and JWT mode asks the Auth service for the password

Next item 7 asked for the design on [boundaries.md](architecture/boundaries.md#a-saga-that-exists-erasing-a-person-across-services) to be built: "events through the outbox, the Auth service deleting by subject, the Notification service storing a recipient id so it can delete by id". The shape was right. The audit found that three things around it mattered more than the parts it listed, and one of them made the design, followed to the letter, **undo itself**.

**What the audit found**
1. **In JWT mode there was no erasure, and giving it one as designed would have been undone by the person's next request.** `DELETE /me` answered `409 managed_by_auth_service`. Lifting that refusal and telling the Auth service afterwards leaves a window, and the window is not short: the tombstone cleared `auth_subject`, the Auth identity stayed until its consumer got to it, and the person's next token (an access token lives 15 minutes; a refresh token lives 30 days and the Auth service keeps honouring it) reached `User.provision_from_claims!`, which found no user for that subject and **created a new one with their real address**. Held by `external_auth_spec`; the mutation run shows it: with the tombstone clearing the subject again, or the guard removed, the erased person is made again. So the Auth step is not clean-up. It is what makes the erasure hold, and until it has happened the Task API has to refuse the identity itself.
2. **The password.** `DELETE /me` asks for it again so that a stolen token alone cannot erase an account (ADR 67). Where the Auth service owns the accounts the Task API has none to check.
3. **An account that was imported at the cutover and has not signed in since has no linked subject.** `legacy_id` is the Task API's id; `auth_subject` is linked at the first JWT sign-in. Deleting "by subject" alone misses exactly the people who exist in the Auth service and are not yet known to the Task API as the same person.
4. **The Auth service had no consumer at all**, and the Notification service's log had the address and no id.
5. **The ids are of two kinds.** A task email's `recipient.id` is the Task API's user id; a password reset's is the Auth service's uid. One column has to hold both, and the event has to carry both.

**What was built**
- **The Task API** writes `user.erased` to the outbox **in the erasure's transaction** (`Events::Outbox.record_erasure`): `user_id` and `auth_subject`, **not the address**, with the id `user.erased:<user id>` so that it is stored once however often it is recorded. It is not a model event (the subject is a tombstone by the time anyone reads it), so the envelope is made there and bypasses the `task|project|comment` routing.
- **The tombstone keeps the subject.** `provision_from_claims!` refuses a subject that belongs to an erased user (`401`), so a token issued before the identity was deleted cannot make the person again; `link_legacy_user` no longer links a tombstone either. The cost: a UUID that points at nothing, once the Auth service has deleted its side, stays in the tombstone. ADR 67 had said "no `auth_subject`"; the guard needs the row to say whose it was.
- **`DELETE /me` in JWT mode** asks the Auth service whether the password is right (`POST /api/v1/credential_checks`, in-cluster only: the ingress does not list it, the same limit on attempts per address as signing in). `204` or `401`, nothing issued. The Auth service that cannot be reached is `503 auth_unavailable`: nothing is erased on a guess. A blank password is refused without asking.
- **The Auth service** has a queue of its own (a subscription filtered on `user.erased`, 14 days, a dead-letter queue after 5 attempts) and a consumer in its Puma process, shaped like the Notification service's. It deletes the account and, with it, every refresh token, found by the subject **and** by `legacy_id = user_id`.
- **The Notification service** records `recipient_id` (a string) next to the address, and `user.erased` deletes the rows of either id the event carries.
- **Infrastructure**: Terraform (the queue, its DLQ and redrive guard, the subscription, the Auth role's grant to consume only that queue, the DLQ alarm and an alarm on the age of the oldest message), the GitOps values for all five environments, the smoke test's queue check, the local aws-init, Compose and kind. `bin/rails erasure:publish` sends the event again for people already erased.

**Decisions**
- **Choreography through the outbox, as designed, not calls from a job.** The alternative was a job in the Task API that calls the Auth and Notification services over HTTP until each says yes, which would also have given the confirmation for free. It needs a credential for each (the shared-token pattern ranked as the weakest hop in the threat model, T15), network policy in both directions, and an internal API on the Notification service, which serves only `/up` and `/metrics`; and the backbone already gives at-least-once, a retry schedule and a dead-letter queue with an alarm.
- **The subject stays on the tombstone, and no table of erased subjects.** The same fact in a second place would need its own retention and its own migration.
- **The password is asked of the Auth service, not read from the token.** A claim saying "recently signed in" is carried by a stolen token as well; signing in again issues tokens and shares the public login's limits; dropping the password in JWT mode would lose the guarantee ADR 67 gave. The endpoint is not public, so it is not a new way to guess a password.
- **The Auth consumer is a copy in shape of the Notification service's, not shared code.** Two consumers do not yet say what the shared part is (they differ in their crash event, their heartbeat, their pruning and their errors); a third would. The cost is that a fix to the loop is made twice.
- **Legacy rows wait.** Delivery-log rows from before `recipient_id` have only the address, which the event does not carry on purpose. They age out under the 90-day retention, and a spec says so.

**Not built: the record of progress.** The first design had a table per (person, step) with `confirmed_at`, filled from confirmation events, and "a step pending for a week raises a ticket". It needs the Task API to read a queue (it has no consumer) and each service to publish a second event. What stands in for it, and what it cannot do: a failed step is a message in a dead-letter queue with an alarm; a service that is not taking events is an alarm on the age of the oldest message (a day, against 14 days of retention); a lost event is sent again with `erasure:publish`; and each consumer counts what it did (`auth_erasures_total{outcome}`, `notifications_erased_deliveries_total`). **What is missing is the per-person answer to "is this one gone everywhere"**, which today is read from empty queues.

**What it does not reach:** events already in flight that carry the address (a `task.assigned` in the outbox for 7 days after it is published, in the queue for up to 4 or 14 days, in a dead-letter queue up to 14), and anything already delivered (an email, a Slack post).

**Verified:**    - **On Docker Compose, through the one address a client has** (`verify.sh`, 25 checks before and **32 now**: the second person cannot erase with a wrong password, erases with the right one, has the token refused at once though it has not expired, is no longer known to the Auth service, and leaves the first person and the work untouched). 32 of 32 on two builds. Then the databases: the Notification log had the erased person's `task.assigned` row gone and the other person's reset row kept; the Auth database had the erased person's account gone; the Task API held the tombstone (`Deleted user`, the subject kept) and `user.erased:8`, published on its first attempt with `{"user_id": 8, "auth_subject": "..."}` and no address in the payload.
   - **A check that cannot fail proves nothing:** with the Auth service's erasure consumer switched off, the same script fails exactly one check (the Auth service deleting the identity) and passes the other 31.
   - **The recovery path, run for real:** with the consumer off, an account was erased; its identity stayed (sign-in 201); the queue was purged (the event lost, as if it had expired); with the consumer back the identity was still there (201); `bin/rails erasure:publish USER_IDS=13` published it once; the next sign-in was 401. The consumers' own counters agree (`auth_erasures_total{outcome="erased"}`, Notification `handled` for both erasures and `duplicate` for the replay of the one it had already seen).
   - **The suites:** the Task API **1,860 examples, 0 failures** as CI runs it (1,840 before; 93.70% line, 83.24% branch; floors 92 and 81), the Auth service 56 (28 before), the Notification service 47 (38 before), the AI service 19; `terraform test` 35 of 35 (a new run of six assertions on the messaging); RuboCop (667 files), Brakeman (the Task API and the three services), `bundler-audit` on the three services' lockfiles, `shellcheck` on `verify.sh`, and the OpenAPI document regenerated.
   - **Mutation-checked: 67 deliberate breakages, all caught** (58 across the Task API, the Auth service, the Notification service, the Helm values and the script, and 9 of the Terraform through `terraform test`). Nothing survived, which I do not take on trust: two were run by hand (without the guard the erased person's old token is answered `200` and the tombstone is renamed back to them; with the tombstone clearing the subject again, `User.count` goes from 1 to 2, the person made again), and one mutant that "survived" was my harness aiming at a method that no longer existed, fixed and re-run. The Terraform run was interrupted once and restored by hand-checking the files and re-running the tests (35 of 35).
   - **Found on the way, fixed here:** (1) the Auth image failed to build in frozen mode because my local `bundle install` left an empty checksum for `aws-sdk-sqs` in `services/auth/Gemfile.lock` (CI would have failed the same way); (2) `spec/support/jwt_helpers.rb` used `JWT` before anything had loaded it, so a JWT spec file run alone failed on nearly every example (it only worked when an earlier file loaded `ExternalAuth`): one `require`; (3) **the secret scan, on this pull request's first CI run, flagged five fixtures**: a made-up UUID given to `auth_subject` in two specs (`generic-api-key`, because the name contains "auth"). One narrow allowlist entry now covers exactly that, and the CI control proves it is narrow in both directions (ten mutations of it and of the control are caught). **The run after it found one more, and it was mine:** the spec for the allowlist wrote a made-up `AKIA…` string as a negative example, and the scanner rightly called it an AWS key. A later commit cannot fix that, because the scan reads every commit; the clean fix is to amend the commit and force-push, which the permission system refused (this is a decision for the person who owns the branch), so the finding was ignored by its **fingerprint** in `.gitleaksignore` (one commit, one file, one rule, one line) while the branch lived, and the line is gone from the spec. The commit is on that pull request's branch and a squash-merge does not keep it, so on `main` the entry matched nothing; it was deleted after the merge, with the file and the spec that described it (the scan on `main` and on the pull request that removed it passes without it). Had it been wanted again, the mechanism is the same: one fingerprint, one reason above it.

**Not verified:** AWS itself: the SNS filter policy, the queue policy, the Auth role's grant, the alarms and the retention are tested against mocked providers (`terraform test`) and the local stack runs moto in their place; nothing was applied, and `start-message-move-task` (the redrive in the runbook) was not run. **The kind cluster was not run on this machine**: the chart renders the Auth release with both settings (`helm template`, for kind's arguments and for the dev environment's GitOps values), and on this pull request's runner `Platform (kind)` passed 32 of 32, the first run of the new queue there (one run is not a sample). Two Auth replicas competing for one queue (SQS gives each message to one), a consumer outage longer than a day (the age alarm), and an erasure under load were reasoned about, not run. The 429 and 503 answers of the password check are specs, not a live Auth service that was slow or limited. The Notification log's older rows wait for retention (a spec says so). No per-person confirmation exists (above).
