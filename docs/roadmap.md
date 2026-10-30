# Roadmap and implementation record

What was planned, what was built, where it lives, and what was deliberately left. Four roadmaps have been worked through, in order;
each section is a ledger, not a plan, so every line says what actually happened.

| # | Roadmap | Delivered in | Result |
| --- | --- | --- | --- |
| 1 | [Build an API-only Rails 8.1 backend](#roadmap-1-build-the-api) (phases 0-7) | [#1](https://github.com/AravindRajeshkanna/rails-task-api/pull/1) | The Task/Project Management API |
| 2 | [AI-powered, AIOps-enabled microservices on AWS EKS](#roadmap-2-ai-aiops-and-microservices-on-eks) (phases 1-6) | [#5](https://github.com/AravindRajeshkanna/rails-task-api/pull/5) | AI features, observability, three extracted services, the platform to run it |
| 3 | [Improve it further](#roadmap-3-improving-the-project-further) (phases 1-8) | [#6](https://github.com/AravindRajeshkanna/rails-task-api/pull/6) | Hardening, testing, performance, security, documentation, organizations, analytics |
| 4 | [The "Next" list](#roadmap-4-the-next-list-of-roadmap-3) (ten items) | [#7](https://github.com/AravindRajeshkanna/rails-task-api/pull/7) | Invitations, organization audit, teams, full-text search, an inbox, keyset pagination, a transactional outbox, a nightly load test, GraphQL, a demo mode; multi-region as a design |

**Status key.** ✅ done and verified as described · 🟡 done in part, or done differently on purpose (the note says how) · ⏭ deliberately not done (the note says why, and what would trigger it).

**What "verified" means here.** The application code is covered by specs that run in CI. The platform code (Docker Compose, `kind`,
Terraform, Helm, Argo CD, Kamal) is validated statically and by CI (images build, Terraform validates, Helm renders and passes schema
checks) but **has never been applied to AWS or run under Docker/Kubernetes**. The AI features run against the offline provider; **Bedrock has
not been called**. Those boundaries are repeated where they matter.

The reasoning behind the non-obvious choices is in [decisions.md](decisions.md) (ADRs 1-44); user-visible changes are in [../CHANGELOG.md](../CHANGELOG.md).

---

## Roadmap 1: Build the API

*Goal: a modern Rails 8.1 API-only backend, project-driven. Delivered in #1 (352 specs then; the suite has grown since).*

| Phase | Planned | Status | Implemented as |
| --- | --- | --- | --- |
| 0 Foundations | Ruby via mise/rbenv/asdf, Rails, Postgres, tooling | ✅ | Ruby 4.0.9 pinned in `mise.toml`/`.ruby-version`; Rails 8.1.4; PostgreSQL 17 |
| 1 Bootstrap & core Rails | `rails new --api`, models, associations, validations, scopes, CRUD, `/api/v1` | ✅ | Users, Projects, Memberships, Tasks, Comments, Tags; `namespace :api { namespace :v1 }`; `config/routes.rb` ([ADR 1-2](decisions.md)) |
| 2 Authentication & authorization | Rails 8 auth or Devise/JWT, Bearer tokens, registration/login/logout/reset, Pundit, 401/403 | ✅ | Database-backed bearer tokens, digest-only ([ADR 3](decisions.md)); Pundit with 404-not-403 across tenants ([ADR 4](decisions.md)); `app/policies` |
| 3 Professional API design | Alba, Pagy, filtering/sorting/search, shallow routes, error envelope, CORS, rack-attack, rswag | ✅ | Alba resources ([ADR 5](decisions.md)); Pagy ([ADR 6](decisions.md)); `TaskQuery`; one error envelope ([ADR 7](decisions.md)); `rack-cors`, `rack-attack`; rswag specs that generate `swagger/v1/swagger.yaml` |
| 4 Advanced Rails 8 | Solid Queue/Cache/Cable, Active Storage, Active Job continuations, structured events, credentials, Kamal 2 | ✅ | The Solid stack ([ADR 8](decisions.md)); `Rails.event` ([ADR 9](decisions.md)); continuations ([ADR 11](decisions.md)); avatars and task attachments; `config/deploy.yml` (Kamal 2) |
| 5 Testing, quality, performance | RSpec/FactoryBot/Faker/Shoulda, request/model/policy specs, Bullet, indexes, RuboCop, Brakeman, local CI | ✅ | See [testing.md](testing.md); Bullet raises in test; `bin/ci` ([ADR 13](decisions.md)) |
| 6 Production readiness | Docker, Kamal, health checks, logging, backups, migrations strategy, Sentry | 🟡 | Dockerfile, `/up`, JSON logs, Sentry were in #1. **Backups and the migration strategy were gaps; closed in roadmap 3** ([backup runbook](runbooks/backup-and-restore.md), [migrations runbook](runbooks/zero-downtime-migrations.md)) |
| 7 Polish & portfolio | Soft delete, auditing, webhooks, GraphQL (optional), multi-tenancy, README, ADRs, public demo | 🟡 | Soft delete + restore, append-only audit log ([ADR 11](decisions.md)), signed SSRF-guarded webhooks ([ADR 10](decisions.md)), README, ADRs ✅. Multi-tenancy: now organizations (roadmap 3). **GraphQL ✅** read-only, in roadmap 4 ([ADR 43](decisions.md)). **Public demo 🟡**: demo mode, a nightly reset and a Kamal destination exist ([docs/demo.md](demo.md), [ADR 44](decisions.md)); hosting it is yours to do |

## Roadmap 2: AI, AIOps and microservices on EKS

*Goal: evolve the monolith into an AI-powered, observable microservice platform on AWS EKS, strangler-fig style. Delivered in #5 (18,000 lines; start at [architecture/overview.md](architecture/overview.md)).*

| Phase | Planned | Status | Implemented as |
| --- | --- | --- | --- |
| 1 AI inside the monolith | LLM features, structured output, guardrails | ✅ | `gems/ai_core` + `Ai::*`: create tasks from text, priority/tags/assignee suggestions, project summaries, a tool-using chatbot; forced tool-call output, re-validated; token budgets; pgvector similarity; eval harness `rake ai:eval` ([ADR 14-17](decisions.md), [architecture/ai.md](architecture/ai.md)). 🟡 Runs on the **offline fake provider**; Bedrock is implemented against the Converse API and **has not been called** |
| 2 Observability + early AIOps | Metrics, traces, logs, anomaly detection | ✅ | Prometheus `/metrics`, OpenTelemetry → X-Ray, JSON logs with trace ids, CloudWatch EMF + anomaly-detection alarms, SNS → PagerDuty/Slack ([ADR 18-19](decisions.md), [architecture/observability-and-aiops.md](architecture/observability-and-aiops.md)) |
| 3 Extract services | Auth, AI, Notification via strangler fig | ✅ | `services/{auth,ai,notifications}`, `gems/service_kit`, CloudEvents on SNS → SQS; Tasks/Projects/Webhooks stay in the monolith on purpose ([ADR 20-23](decisions.md), [architecture/microservices.md](architecture/microservices.md)) |
| 4 Containers + local Kubernetes | Docker, Compose, `kind` | 🟡 | Dockerfiles (CI builds all four images), `docker-compose.yml`, `deploy/local/up.sh`. **Compose and `kind` have not been run** (no Docker daemon on the authoring machine) |
| 5 Production EKS | Terraform, Karpenter, Argo CD, GitOps | 🟡 | Terraform (VPC, EKS, Karpenter, Aurora, SNS/SQS, WAF, ECR, OIDC), one Helm chart, Argo CD ApplicationSets, Rollouts, KEDA, Pod Identity ([ADR 24-26](decisions.md), [aws/setup-guide.md](aws/setup-guide.md)). `terraform validate`, Helm rendering and schema checks pass in CI; **nothing was applied to AWS** |
| 6 Advanced AIOps | RCA, safe auto-remediation, chaos, cost | 🟡 | RCA and remediation Lambdas (dry run by default), FIS experiments, Budgets and Cost Anomaly Detection ([ADR 27](decisions.md)). Lambdas are specced; the AWS wiring is unapplied |

## Roadmap 3: Improving the project further

*Goal: take the project from a solid learning build to a production-ready portfolio piece, in eight phases. Delivered in #6.*

### Phase 1: Code quality and architecture

| Planned | Status | Implemented as |
| --- | --- | --- |
| Strict RuboCop + StandardRB | ✅ | Extended omakase with the Lint/Rails/Performance departments and complexity limits; StandardRB deliberately not adopted ([ADR 29](decisions.md)). `.rubocop.yml`; 8 pre-existing methods are listed in `.rubocop_todo.yml` as visible debt |
| Service objects / interactors / commands | 🟡 | Controllers were already thin, so no wholesale refactor. A convention and base class (`ApplicationCommand`) plus three real commands (`Organizations::Create/AddMember/RemoveMember`) ([ADR 30](decisions.md)) |
| Form objects / dry-validation | ✅ | `ApplicationForm` (ActiveModel) and `Analytics::ReportForm`; dry-validation not added ([ADR 30](decisions.md)) |
| Centralized `ErrorSerializer`, consistent errors | ✅ | `ErrorSerializer` replaces three hand-written envelopes (controllers, exceptions app, Rack::Attack); errors now carry `request_id` |
| Proper `/api/v1`, prepare v2 | ✅ | `/api/v1` since #1; now `API-Version` on every response and `Deprecation`/`Sunset` headers for retiring a version; [api-versioning.md](api-versioning.md) is the v2 guide |
| Alba, no `as_json` | ✅ | Since #1 (`app/resources`); the analytics report is the one hash payload, built from explicit keys |
| DB constraints, indexes, foreign keys | ✅ | Foreign keys since #1. Now CHECK constraints (11 on existing tables), validated in a second migration; `strong_migrations` guards future ones; one index added because `EXPLAIN` demanded it ([ADR 31](decisions.md), [performance.md](performance.md)) |
| ADR document | ✅ | [decisions.md](decisions.md): 1-13 (#1), 14-28 (#5), 29-34 (#6) |

### Phase 2: Testing

| Planned | Status | Implemented as |
| --- | --- | --- |
| High coverage on critical paths | ✅ | SimpleCov line and branch: 92.8% / 82.1%; policies, models and controllers at 96-100% ([testing.md](testing.md#coverage)) |
| Request specs for every endpoint | ✅ | rswag + request specs; `api_docs_spec` fails on an undocumented route; `tenant_isolation_spec` fails on a route with no isolation decision |
| Model + policy specs | ✅ | `spec/models`, `spec/policies` (including organization access and role matrices) |
| FactoryBot + Faker + Shoulda | ✅ | In place since #1 |
| Integration tests for auth flows | ✅ | `authentication_spec` (pieces) and `authentication_journey_spec` (sign up → work → reset password → signed out everywhere) |
| VCR or WebMock | 🟡 | WebMock ✅. VCR deliberately not added: outbound calls are webhooks and AWS SDK calls, which stub cleanly without cassettes that record real responses ([testing.md](testing.md#decisions)) |
| SimpleCov with a CI floor | ✅ | `COVERAGE=1`; floor 92% line / 81% branch (raised from 91 / 79 as the suite grew) in `spec/spec_helper.rb`; CI uploads the report and prints it in the job summary |
| Parallel testing if the suite grows | ⏭ | 1,036 examples run in ~20 s; parallelism would add cost for no gain. Trigger: suite past ~2 minutes ([testing.md](testing.md#decisions)) |
| *Found on the way* | ✅ | `rspec <file>` ran the whole suite because of a `--pattern` in `.rspec`; the gem and Lambda specs had hidden dependencies on the booted Rails app. Both fixed; every way of running the specs now works |

### Phase 3: Performance and scalability

| Planned | Status | Implemented as |
| --- | --- | --- |
| Eliminate N+1 (Bullet) | ✅ | Bullet raises in test since #1; new endpoints also assert query counts (`count_queries`) |
| Indexes from real query patterns | ✅ | 149,000-task data set, `EXPLAIN (ANALYZE)` on ten hot queries: nine already index-served, one fixed (200x at the database, 2.3x end to end under load). No speculative indexes ([performance.md](performance.md)) |
| Pagination, filtering, sorting | ✅ | Pagy, `TaskQuery` (since #1); page 400 of a 50k-task project: 3.5 ms |
| HTTP caching headers | 🟡 | ETag via `Rack::ETag` (body hash, correct by construction), explicit `Cache-Control: no-cache, private`, `Vary`, `no-store` on credentials, 304 tested. No `Last-Modified`, no controller-level `fresh_when` ([ADR 32](decisions.md)) |
| Fragment / Russian-doll caching | 🟡 | Where it is safe: project stats and the analytics report, keyed by project version. Not on task/project JSON, whose representation depends on associated records and signed URLs ([ADR 32](decisions.md)) |
| Background jobs | ✅ | Solid Queue since #1 |
| `rack-attack` | ✅ | Since #1; now with an `RACK_ATTACK_ENABLED` switch (load tests, emergencies) |
| Load testing with k6, results documented | ✅ | `loadtest/` (k6 script, seeder); one Puma process carries ~260 req/s at p95 30 ms with no errors and saturates before 80 visits/s ([performance.md](performance.md)). Laptop numbers, for comparison, not capacity planning |

### Phase 4: Security

| Planned | Status | Implemented as |
| --- | --- | --- |
| Strong authentication | ✅ | Bearer sessions (#1); RS256 JWT + rotating refresh tokens in the Auth service (#5) |
| Pundit / Action Policy | ✅ | Pundit, default deny, `verify_authorized` |
| `secure_headers` | ✅ | `config/initializers/secure_headers.rb`: deny-all CSP, `X-Frame-Options: DENY`, `nosniff`, `Referrer-Policy`; Swagger UI excepted; covers answers produced before routing ([ADR 33](decisions.md)) |
| Strong parameters + input sanitization | ✅ | `permit` everywhere; names and titles normalized; allow-listed query parameters; uploads validated. Output is JSON, so there is no HTML to sanitize, and the doc says clients must escape ([security.md](security.md)) |
| Secrets management | ✅ | Credentials + environment locally; Secrets Manager + External Secrets on EKS (#5) |
| Brakeman + bundler-audit in CI | ✅ | Since #1, extended to the services in #5 |
| CORS | ✅ | Allow-list, nothing by default in production |
| Mass assignment, IDOR, common API vulnerabilities | ✅ | Tenant isolation sweep over every route; mass-assignment specs; OWASP API Top 10 mapped control by control in [security.md](security.md) |

### Phase 5: Developer experience and documentation

| Planned | Status | Implemented as |
| --- | --- | --- |
| Excellent README | ✅ | [README](../README.md), updated for everything above |
| OpenAPI / Swagger (rswag) | ✅ | `/api-docs`; the document is generated from specs and CI fails if it is stale |
| API changelog | ✅ | [CHANGELOG.md](../CHANGELOG.md) |
| Docker Compose, one command | 🟡 | `docker compose up` (#5) is **unrun** |
| Contribution guidelines | ✅ | [CONTRIBUTING.md](../CONTRIBUTING.md), PR and issue templates, [SECURITY.md](../SECURITY.md) |
| GitHub Actions: test, lint, security | ✅ | `.github/workflows/ci.yml` (also services, infrastructure, images); coverage floor and report added |

### Phase 6: Feature expansion

| Planned | Status | Implemented as |
| --- | --- | --- |
| Soft deletes + auditing | ✅ | #1 |
| Activity feed / notifications | 🟡 | Activity feed: `GET /activity`, the member's view of the audit log across their projects. Email and Slack notifications via the Notification service (#5). **In-app inbox with read state ✅** (roadmap 4, [ADR 39](decisions.md)) |
| File attachments (Active Storage + S3) | ✅ | Local disk, or S3 with `ACTIVE_STORAGE_SERVICE=amazon` (#5) |
| Advanced search | 🟡 | Trigram-indexed title search and substring search (#1); semantic similar-task search with pgvector (#5). **Full-text search ✅** (roadmap 4, [ADR 38](decisions.md)): ranked, with highlights, within a project and across projects |
| Webhooks | ✅ | #1 |
| Multi-tenancy | ✅ | Organizations are the tenant boundary: a project belongs to one for life and only takes its members ([ADR 34](decisions.md)). Row-level security / schema-per-tenant ⏭, not needed at this scale |
| Real-time updates | ✅ | Solid Cable `ProjectChannel` (#1) |
| AI features | ✅ | #5 |
| Usage analytics dashboard | ✅ | `GET /projects/{id}/analytics`: counts, throughput per period, cycle time (median/p90), workload. Backend only; no UI in this repository |
| RBAC with teams/organizations | ✅ | Organizations with `owner`/`admin`/`member`, admins administering all org projects, last-owner and removal rules; policy, model and request specs. **Teams** (roadmap 4, [ADR 37](decisions.md)): groups granted a role in a project, derived in the policies; invitations ([ADR 35](decisions.md)) and an organization audit log ([ADR 36](decisions.md)) |

### Phase 7: DevOps and deployment

| Planned | Status | Implemented as |
| --- | --- | --- |
| Dockerize properly | ✅ | Multi-stage Dockerfile; CI builds all four images |
| Kamal 2 or CI/CD to a PaaS | 🟡 | `config/deploy.yml` (placeholders, never run); GitHub Actions deploy/promote workflows for EKS (#5), unapplied |
| Move to EKS | 🟡 | Full Terraform + GitOps (#5), validated statically, unapplied |
| Staging + production | 🟡 | Terraform `dev`/`staging`/`prod` tfvars and per-environment Argo CD apps with auto-sync for non-prod and manual sync for prod; unapplied |
| Backups, migrations strategy, zero-downtime | ✅ | Aurora PITR (14 days in prod) configured in Terraform; [backup runbook](runbooks/backup-and-restore.md) whose `pg_dump`/`pg_restore` procedure was run end to end on 149k tasks; `strong_migrations` + [migrations runbook](runbooks/zero-downtime-migrations.md); canary rollouts with analysis (#5). The Aurora and Kamal-wrapper commands in the runbook are unrun |
| Monitoring and alerting | ✅ | Sentry (#1); Prometheus, Grafana, CloudWatch alarms, PagerDuty/Slack (#5) |
| Structured logging | ✅ | JSON logs with request and trace ids (#1, #5) |

### Phase 8: Advanced / portfolio differentiation

| Planned | Status | Implemented as |
| --- | --- | --- |
| Extract 1-2 microservices | ✅ | Auth, AI and Notifications (#5) |
| Full observability (OpenTelemetry + Grafana) | ✅ | #5 |
| Event-driven pieces (SQS / EventBridge) | ✅ | CloudEvents on SNS → SQS (+ DLQ), EventBridge rules (#5) |
| AIOps experiments (anomaly detection) | ✅ | CloudWatch anomaly detection, RCA and remediation Lambdas (#5) |
| Multi-region or advanced AWS | 🟡 | Advanced AWS in place (Karpenter, Pod Identity, WAF, FIS, Budgets). **Multi-region 🟡 built and tested offline, never applied**: Terraform (`dr_role`, one root module applied twice), a `prod-dr` GitOps environment, [the design](aws/multi-region.md), [the failover runbook](runbooks/regional-failover.md), [ADR 42](decisions.md) and [45](decisions.md) |

---

## Roadmap 4: the "Next" list of roadmap 3

*Goal: work through the ten items the previous roadmap ended with, in that order. Delivered in [#7](https://github.com/AravindRajeshkanna/rails-task-api/pull/7), one commit per item.*

| # | Item | Status | Implemented as |
| --- | --- | --- | --- |
| 1 | Invitation flow | ✅ | `OrganizationInvitation` with a signed, expiring token (nothing secret stored or queued); redeeming needs the token and being the invited address; the API answers the same for registered and unregistered addresses; project add-by-email in an organization answers the same for an unknown address as for a stranger ([ADR 35](decisions.md)) |
| 2 | Audit organization changes | ✅ | `audit_events.organization_id`, `Auditable` records deletions on request; `GET /organizations/{id}/audit_events` for owners ([ADR 36](decisions.md)) |
| 3 | Teams | ✅ | `Team`, `TeamMembership`, `ProjectTeam`; access derived in `ProjectPolicy::Scope`, `member_project_ids` and `role_in` (highest role wins); assignable; found and fixed an inconsistency between list and single-record role lookups ([ADR 37](decisions.md)) |
| 4 | Full-text search | ✅ | stored `tsvector` + GIN, `websearch_to_tsquery`, ranked, highlights; `?search=` and `GET /search`. Rare word 62 ms → 2 ms; a word in 60% of 50k tasks is 21 ms *slower* than substring search, so both stay ([ADR 38](decisions.md)) |
| 5 | In-app notification inbox | ✅ | `Notification` written by one more `Rails.event` subscriber; `GET /notifications`, read/unread, `read_all`, live over Action Cable; hidden when access ends ([ADR 39](decisions.md)) |
| 6 | Keyset pagination | ✅ | `?cursor=` on the task list, built on Pagy's keyset paginator with microsecond cutoffs and validated cursors; 13.8 ms → 0.08 ms at row 49,000; for `created_at`, `updated_at` and `title` sorts ([ADR 40](decisions.md)) |
| 7 | Transactional outbox | ✅ | `outbox_events` written in the change's transaction, envelope built then; a leased, backed-off relay; alarm on the oldest unpublished event; runbook ([ADR 41](decisions.md)) |
| 8 | A load test in CI | ✅ | `.github/workflows/loadtest.yml` runs `loadtest/ci.sh` nightly, on demand and when the load test changes; fails on any k6 threshold (now including dropped iterations); opens an issue when the nightly run fails. The script ran end to end locally, passing and breaching, and the workflow ran green on GitHub in the pull request that added it (about 2 minutes; see the numbers in [performance.md](performance.md#full-text-search)) |
| 9 | Multi-region | 🟡 | Built, **never applied**: `dr_role` in the one Terraform root module (a global Aurora cluster, S3 and ECR replication, secret replicas, a Route 53 failover pair with a health check), a `prod-dr` GitOps environment and promotion path, a standby sized by `SIZE_AS`, a design, a failover runbook, and `terraform test` against mocked providers in CI (mutation-checked; it found two defects in the existing code). The roadmap's condition ("after a single region has run in anger") is still unmet, so the first real apply is expected to teach something ([ADR 42](decisions.md), [45](decisions.md)) |
| 10 | GraphQL and a public demo | ✅ / 🟡 | GraphQL: read-only, authorized by the policy scopes, with hard limits and a committed schema ([ADR 43](decisions.md)). Demo: `DEMO_MODE`, a nightly reset, a seeded dataset, a Kamal destination validated with `kamal config`; **not hosted**, which only you can do ([ADR 44](decisions.md)) |

## Roadmap 5: the "Next" list of roadmap 4

*Goal: work through the eight items the previous roadmap ended with, in that order. One commit per item. Two of them cannot be finished from a laptop (an AWS account, a host); the rows say what was done and what is left.*

| # | Item | Status | Implemented as |
| --- | --- | --- | --- |
| 1 | A read-only switch | ✅ | `ReadOnlyMode` middleware: a refused write is `503 read_only` with `Retry-After`; `READ_ONLY=true` refuses writes up front; the standby renders with it on and the production-size render turns it off. Making *reads* survive needed two more fixes (the session usage stamp, and Solid Cache on a read-only database). Checked against a Postgres that really refuses writes, not against Aurora ([ADR 46](decisions.md)) |
| 2 | Cross-region snapshot copy | 🟡 | `backup_copy_region` in the Terraform: an AWS Backup plan (daily snapshot, copied to a vault in another region, alert on failure) and a replicated dump bucket with a write-only upload policy; `db_dump.sh` and `db_restore_check.sh` (a dump is verified before it is kept; the restore reports its time and row counts), run against the 149,000-task database. **Never applied**; `terraform test` against mocks, mutation-checked; `aws` and `age` not run ([ADR 47](decisions.md), [runbook](runbooks/backup-and-restore.md#a-copy-in-another-region)) |
| 3 | Apply the multi-region pair, in staging, and run the drill | 🟡 | **Not applied, not run:** needs an AWS account, and the item's own condition (a single region that has run for months, a stated RTO/RPO) is unmet. What was built to make the first attempt cheap: `envs/staging-dr.*`, a `staging-dr` GitOps environment (rendered, CI-checked, auto-synced, promotable), a `terraform test` for its names, [the drill runbook](runbooks/failover-drill.md) with a record sheet, and `deploy/scripts/drill_probe.rb`, which measures the drill from the client side (outage windows, the answers, time to full service, acknowledged writes lost). The probe ran against a live local server restarted into read-only mode and back (13 s to full service, 0 of 27 writes lost); its tests are in `spec/scripts/drill_probe_spec.rb` |
| 4 | Per-person notification settings | ✅ | `notification_mutes` (a kind, a project, or a kind in a project; not written, not emailed, not digested) and `notification_settings` (a daily digest at a chosen hour in the person's time zone instead of an email per event); `NotificationDigestJob` hourly; `recipient.email_enabled` on the events so the Notification service honours it; refused for the digest in the public demo. Mutation-checked: six deliberate breakages each fail a spec ([ADR 49](decisions.md)) |
| 5 | Cap a broad ranked search; keyset for other growing lists | ✅ / not built | **Measured both.** Audit logs (project, organization) and `GET /activity` take `?cursor=` (1,000,000 events: first page 23 ms by offset, 0.6 ms by cursor). The feed needed a new query as well: a cursor on the obvious one was 108 ms against 109 ms, because PostgreSQL sorts every event of the caller's projects; `ActivityFeed` merges each project's newest events in index order: 1.3 ms at any depth, same results. **The ranked-search cap was not built**: 21 to 2.4 ms in one project, 22 to 23 ms across projects (the slow shape, where finding the matches is the cost), for a change in what a search returns ([ADR 50](decisions.md), [numbers](performance.md#the-lists-that-only-grow-audit-logs-and-the-activity-feed)) |

## Next

Ordered by what a real user would hit first.

3. **Apply the staging pair and run the first drill** ([runbook](runbooks/failover-drill.md)), then production's once a single region has run for a few months and an RTO/RPO is stated ([design](aws/multi-region.md#building-it-in-this-order)). Everything it needs is written; what is missing is an account and an afternoon.
5. **If cross-project search ever becomes the slow endpoint**, require a project (or a short list) for a broad query, or add an index that answers "newest matches first" across projects. Capping the ranking was measured and does not help there ([ADR 50](decisions.md)).
6. **GraphQL mutations or subscriptions**, only if a client needs them; REST and Action Cable already cover both.
7. **Teams with roles** (team maintainers who manage membership) and **nested teams**, if organizations outgrow flat groups.
8. **Hosting the demo**, and a front end to point at it.

## How this was verified

| Claim | Evidence |
| --- | --- |
| The application behaves as documented | 1,036 examples across the app, shared gems and Lambdas (+72 in the three services), run with branch coverage in CI |
| Search, deep paging and the inbox are fast | `EXPLAIN (ANALYZE)` and in-process timings on a 149,000-task database, 300,000 synthetic notifications ([performance.md](performance.md), the ADRs) |
| The outbox loses nothing | specs: rolled-back changes leave no event; a failing SNS keeps the event and delivers it exactly once when it returns; two relays never send the same row (including from four threads); a request through to a stubbed SNS |
| Access is as documented | `tenant_isolation_spec` (every route, now including teams, invitations, search, the inbox, GraphQL), `project_policy_team_spec` (both role lookups agree for every combination), `graphql_spec` ("who can see what") |
| The load-test script works | `loadtest/ci.sh` ran locally end to end: a passing run, and a deliberately overloaded one that exited 99, listed the breached thresholds and cleaned up |
| Backups restore | `pg_dump` → `pg_restore` of the same database; row counts, constraints and the `vector` extension checked |
| The multi-region wiring is right | `terraform test` (in CI): the whole configuration is planned and applied against mocked AWS providers for a single region, a primary before and after its standby is ready, and a standby; mutation-checked ([ADR 45](decisions.md)). Proves what each role creates, not that AWS accepts it |
| Migrations are safe | `strong_migrations` accepted every migration but one: the full-text column, which rewrites `tasks` under a lock (3.7 s for 149,000 rows) and is marked `safety_assured` with that number ([runbook](runbooks/zero-downtime-migrations.md)) |
| **Not verified** | Docker Compose, `kind`, any Terraform plan/apply against a real account (the multi-region pair is checked only offline, against mocks), Kamal deploys (the demo destination only passes `kamal config`), Bedrock with real credentials, the Aurora restore commands, hosting the demo |
