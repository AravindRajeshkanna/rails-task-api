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
