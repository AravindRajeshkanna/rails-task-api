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
step if an event must never be lost across a database commit and an SNS outage.

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

- **GraphQL**, a **public demo**, and an actual **deploy**: the roadmap's Phase 7 items were out of scope; deployment is
  yours to run from the guide.
- **Service mesh** (Istio/App Mesh): mTLS and traffic policy are not needed for five services behind NetworkPolicies and
  signed tokens; App Mesh is also being retired by AWS. Revisit past ~10 services.
- **CloudFront**: there are no public static assets; the API sits behind the ALB and WAF.
- **Amazon MQ / Redis**: SNS/SQS cover messaging; Solid Cache/Queue cover caching and jobs.
- **Moving webhooks into the Notification service**: webhook configuration is project data owned by the monolith; the
  service handles email and Slack. The event stream makes that move mechanical when wanted.
