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
