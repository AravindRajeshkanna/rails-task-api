# Roadmap and implementation record

What was planned, what was built, where it lives, and what was deliberately left. Eight roadmaps have been worked through, in order;
each section is a ledger, not a plan, so every line says what actually happened.

| # | Roadmap | Delivered in | Result |
| --- | --- | --- | --- |
| 1 | [Build an API-only Rails 8.1 backend](#roadmap-1-build-the-api) (phases 0-7) | [#1](https://github.com/AravindRajeshkanna/rails-task-api/pull/1) | The Task/Project Management API |
| 2 | [AI-powered, AIOps-enabled microservices on AWS EKS](#roadmap-2-ai-aiops-and-microservices-on-eks) (phases 1-6) | [#5](https://github.com/AravindRajeshkanna/rails-task-api/pull/5) | AI features, observability, three extracted services, the platform to run it |
| 3 | [Improve it further](#roadmap-3-improving-the-project-further) (phases 1-8) | [#6](https://github.com/AravindRajeshkanna/rails-task-api/pull/6) | Hardening, testing, performance, security, documentation, organizations, analytics |
| 4 | [The "Next" list](#roadmap-4-the-next-list-of-roadmap-3) (ten items) | [#7](https://github.com/AravindRajeshkanna/rails-task-api/pull/7) | Invitations, organization audit, teams, full-text search, an inbox, keyset pagination, a transactional outbox, a nightly load test, GraphQL, a demo mode; multi-region as a design |
| 5 | [The "Next" list of roadmap 4](#roadmap-5-the-next-list-of-roadmap-4) (eight items) | [#9](https://github.com/AravindRajeshkanna/rails-task-api/pull/9) | A read-only mode, cross-region backup copies, a failover drill kit, notification settings, cursor paging for the audit logs and a fast activity feed, GraphQL mutations, team maintainers and nested teams, a demo front end; two items could not be finished here and one was measured and not built |
| 6 | [Improve it from a system-design perspective](#roadmap-6-improving-it-from-a-system-design-perspective) (eight phases) | [#10](https://github.com/AravindRajeshkanna/rails-task-api/pull/10) | Idempotency keys, replicas, circuit breakers, load shedding, SLO alerts, session lifecycle, account erasure and retention, a threat model, and the architecture written down. Found that the API's metrics could never be scraped |
| 7 | [AWS KMS and one-click provisioning](#roadmap-7-aws-kms-and-one-click-provisioning) (seven phases, plus a manual Terraform workflow) | [#11](https://github.com/AravindRajeshkanna/rails-task-api/pull/11) | Email addresses and webhook secrets encrypted with keys KMS protects, a key per purpose with the data key replicated for the standby, rotation by generation, a KMS-only audit trail with alarms, SSE-KMS for files and Secrets Manager, and a **Provision AWS** workflow. None of it applied to AWS |
| 8 | [Only the owner reaches AWS](#roadmap-8-only-the-owner-reaches-aws) (a hardening request, audited rather than checklisted) | not yet raised | A fork-triggered deploy closed, the AWS roles trusting the subject this repository's tokens actually carry, all five Environments locked to `main` with the owner as reviewer, and a script that keeps GitHub's settings that way. Not exercised by a real run |

**Status key.** ✅ done and verified as described · 🟡 done in part, or done differently on purpose (the note says how) · ⏭ deliberately not done (the note says why, and what would trigger it).

**What "verified" means here.** The application code is covered by specs that run in CI. The platform code (Docker Compose, `kind`,
Terraform, Helm, Argo CD, Kamal) is validated statically and by CI (images build, Terraform validates, Helm renders and passes schema
checks) but **has never been applied to AWS or run under Docker/Kubernetes**. The AI features run against the offline provider; **Bedrock has
not been called**. Those boundaries are repeated where they matter.

The reasoning behind the non-obvious choices is in [decisions.md](decisions.md) (ADRs 1-71); user-visible changes are in [../CHANGELOG.md](../CHANGELOG.md).

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
| Parallel testing if the suite grows | ⏭ | 1,343 examples run in ~40 s; parallelism would add cost for no gain. Trigger: suite past ~2 minutes ([testing.md](testing.md#decisions)) |
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

*Goal: work through the eight items the previous roadmap ended with, in that order. One commit per item (two for item 7). Two of them cannot be finished from a laptop (an AWS account, a host); one was measured and not built; three were built without the evidence the roadmap asked for first. The rows say which.*

| # | Item | Status | Implemented as |
| --- | --- | --- | --- |
| 1 | A read-only switch | ✅ | `ReadOnlyMode` middleware: a refused write is `503 read_only` with `Retry-After`; `READ_ONLY=true` refuses writes up front; the standby renders with it on and the production-size render turns it off. Making *reads* survive needed two more fixes (the session usage stamp, and Solid Cache on a read-only database). Checked against a Postgres that really refuses writes, not against Aurora ([ADR 46](decisions.md)) |
| 2 | Cross-region snapshot copy | 🟡 | `backup_copy_region` in the Terraform: an AWS Backup plan (daily snapshot, copied to a vault in another region, alert on failure) and a replicated dump bucket with a write-only upload policy; `db_dump.sh` and `db_restore_check.sh` (a dump is verified before it is kept; the restore reports its time and row counts), run against the 149,000-task database. **Never applied**; `terraform test` against mocks, mutation-checked; `aws` and `age` not run ([ADR 47](decisions.md), [runbook](runbooks/backup-and-restore.md#a-copy-in-another-region)) |
| 3 | Apply the multi-region pair, in staging, and run the drill | 🟡 | **Not applied, not run:** needs an AWS account, and the item's own condition (a single region that has run for months, a stated RTO/RPO) is unmet. What was built to make the first attempt cheap: `envs/staging-dr.*`, a `staging-dr` GitOps environment (rendered, CI-checked, auto-synced, promotable), a `terraform test` for its names, [the drill runbook](runbooks/failover-drill.md) with a record sheet, and `deploy/scripts/drill_probe.rb`, which measures the drill from the client side (outage windows, the answers, time to full service, acknowledged writes lost). The probe ran against a live local server restarted into read-only mode and back (13 s to full service, 0 of 27 writes lost); its tests are in `spec/scripts/drill_probe_spec.rb` |
| 4 | Per-person notification settings | ✅ | `notification_mutes` (a kind, a project, or a kind in a project; not written, not emailed, not digested) and `notification_settings` (a daily digest at a chosen hour in the person's time zone instead of an email per event); `NotificationDigestJob` hourly; `recipient.email_enabled` on the events so the Notification service honours it; refused for the digest in the public demo. Mutation-checked: six deliberate breakages each fail a spec ([ADR 49](decisions.md)) |
| 5 | Cap a broad ranked search; keyset for other growing lists | ✅ / not built | **Measured both.** Audit logs (project, organization) and `GET /activity` take `?cursor=` (1,000,000 events: first page 23 ms by offset, 0.6 ms by cursor). The feed needed a new query as well: a cursor on the obvious one was 108 ms against 109 ms, because PostgreSQL sorts every event of the caller's projects; `ActivityFeed` merges each project's newest events in index order: 1.3 ms at any depth, same results. **The ranked-search cap was not built**: 21 to 2.4 ms in one project, 22 to 23 ms across projects (the slow shape, where finding the matches is the cost), for a change in what a search returns ([ADR 50](decisions.md), [numbers](performance.md#the-lists-that-only-grow-audit-logs-and-the-activity-feed)) |
| 6 | GraphQL mutations or subscriptions | ✅ / not built | Five mutations (`createTask`, `updateTask`, `deleteTask`, `createComment`, `markNotificationRead`) that are the REST writes reached another way: the same scope, policy and model, so nothing is decided twice; payload `errors` for mistakes, `extensions.code` for not found / forbidden / stale; one mutation per request so the rate limit still counts writes. Spec'd against REST (same input, same answers), against skipped scopes and policies (eleven breakages, each caught). **Built without a client that needs it** (the roadmap's condition is unmet). **Subscriptions not built** ([ADR 51](decisions.md)) |
| 7 | Teams with roles; nested teams | ✅ | **Maintainers:** a team member is a `member` or a `maintainer`; a maintainer adds and removes the plain members of their own team and nothing else (cannot appoint, change roles, remove maintainers or themselves); no project access of its own ([ADR 52](decisions.md)). **Nesting, one level:** a sub-team's members have what its parent was granted; one rule in `Team.granting_to`/`with_sub_teams` behind all four places access is computed; +0.4 ms on the 1 ms scoped query. Both mutation-checked (5 and 9 breakages, each caught). Built without evidence that organizations outgrew flat groups ([ADR 53](decisions.md)) |
| 8 | Hosting the demo; a front end to point at it | 🟡 | **Front end built:** `demo/web`, static files with no build step or dependencies (sign in, projects, a board, task details and comments, an inbox, a demo banner); `build.sh` writes it for your API; 32 tests in CI incl. hostile text through every screen; run against a real demo server and driven in jsdom (not repeatable from here). Found and fixed on the way: the API did not expose `X-Demo-Mode` to browsers. **Not hosted** (your server and domain) and **never looked at in a browser** ([ADR 54](decisions.md)) |

## Roadmap 6: improving it from a system-design perspective

*Goal: audit the system against an eight-phase system-design checklist (data and API design, performance, reliability, scalability, observability, security, distributed systems, high availability), build what was genuinely missing, and write down the rest. Delivered as one commit per item on one pull request. Each row says whether the item **existed** (audited, nothing to build), was **built** (with the measurement that justified it), was **measured and not built**, or is **a design only**. Nothing here has been applied to AWS or a cluster.*

| Phase | Item | Status | Implemented as |
| --- | --- | --- | --- |
| 1 Data and API | Schema, indexes, soft delete, audit columns, errors, pagination, filtering, versioning | existed | Audited. `updated_by` is deliberately absent (the audit trail answers it) |
| | Idempotency keys | built | `Idempotency-Key` on every create: the answer is stored in the write's transaction, fingerprinted, replayed or refused ([ADR 55](decisions.md)) |
| | Sparse fieldsets | built | `fields=` that skips the work (associations not loaded), not only the bytes ([ADR 56](decisions.md)) |
| | Index and write-path cost | measured; one removed | Each index priced; an unused trigram index dropped (17% of every task insert, no reads). Counts kept exact: the cache-busting touch costs 28% of write throughput but does not serialize writers, with a documented trigger for eventual consistency ([ADR 57](decisions.md)) |
| 2 Performance | Read replicas | built | Opt-in per controller, read-your-writes through a marker, never a reason for a request to fail; verified against a local replica, not Aurora ([ADR 60](decisions.md)) |
| | Caching and invalidation | built | By key version, not by delete ([ADR 61](decisions.md)) |
| 3 Reliability | Circuit breakers, jittered retries, stale-if-error for keys | built | A per-process breaker with doubling pauses and one probe, equal-jitter backoff, JWKS served stale for a day ([ADR 58](decisions.md)) |
| | Priority queues, bulkheads | built | Worker pools per queue; the queue a job runs in is a decision ([ADR 59](decisions.md)) |
| 4 Scalability | Rate limits per user, organization and endpoint; backpressure | built | Organization write budgets, endpoint throttles, load shedding on the Puma backlog; queue-based load leveling documented ([ADR 62](decisions.md)) |
| | Archival, retention, sharding readiness | built / design | Three tables that grew for ever now have retention jobs (webhook deliveries, invitations, the Notification service's log; the purge measured at 1.3 s for a million rows). The audit trail's archival is a written plan with triggers. A spec classifies every table by tenant and fails on a new one ([ADR 67](decisions.md), [data-lifecycle.md](architecture/data-lifecycle.md)). Sharding is **not recommended**; the blockers are listed |
| 5 Observability | Organization in every log line and trace | built | `Current.organization_id` into event context and spans ([ADR 62](decisions.md)) |
| | Liveness versus readiness | built | `/livez` and `/readyz`; probes, load balancer and DNS health check moved to readiness ([ADR 63](decisions.md)) |
| | SLOs and burn-rate alerts | built | Multi-window alerts, tested with promtool against synthetic traffic ([ADR 64](decisions.md), [slo.md](slo.md)) |
| | Capacity planning | built | Arithmetic on measured numbers, with the database connection limit as the wall ([ADR 65](decisions.md), [capacity-planning.md](capacity-planning.md)) |
| | **A bug found by following a secret** | fixed | The API demanded `METRICS_TOKEN` and the PodMonitor sent none: Prometheus would never have scraped it, and the SLO alerts would have been silent. Fixed, guarded by a spec, and `TaskApiNotScraped` alerts on missing data ([ADR 68](decisions.md)) |
| 6 Security | Token rotation, refresh, idle timeout | built (local mode) | `POST /session/rotate`, a 14-day idle timeout, `GET /sessions`, `DELETE /sessions/:id` ([ADR 66](decisions.md)); the Auth service already rotates refresh tokens |
| | PII and data protection | built / design | `DELETE /me` anonymises in place; the inventory says what is held, for how long, and what erasure does not reach ([ADR 67](decisions.md), [data-protection.md](data-protection.md)) |
| | Secrets rotation | runbook | Every secret, how it reaches a pod, how to rotate it, what to expect ([secrets-rotation.md](runbooks/secrets-rotation.md)); never run |
| | Threat model, zero trust | design | Assets, actors, boundaries, 23 threats with what stops each and what remains, hop-by-hop trust ([threat-model.md](threat-model.md)) |
| 7 Distributed systems | Bounded contexts, data ownership, saga | design | Contexts with owners and the places the rules bend; the one multi-owner change (erasure across services) designed as a forward-only process with a progress record ([boundaries.md](architecture/boundaries.md)). Not built |
| 8 High availability | Failure domains, blast radius, chaos | design | Every domain from request to region with what users see, and the shared fate that matters most (one Aurora cluster under the API, the queue, the cache and sign-in); ten game-day experiments with hypotheses ([failure-domains.md](architecture/failure-domains.md)). **None has been run** |

## Roadmap 7: AWS KMS and one-click provisioning

*Goal: integrate AWS KMS for the sensitive data (a seven-phase checklist: the key and its permissions, Rails setup, what to encrypt, security practice, testing, rotation and operations, advanced uses), and add a way to run Terraform from CI by hand, in one click, that sets up the AWS resources all at once. As before: audit first, build only the gap, measure before deciding, mutation-check, say what was not run. **Nothing here was applied to AWS or run on GitHub's runners.***

| Phase | Item | Status | Implemented as |
| --- | --- | --- | --- |
| 1 AWS foundation | A symmetric key, rotation on, an alias | built | Three keys per environment (data, storage, secrets), rotating yearly; the data key is **multi-Region** and always was, because the standby reads the same database and a single-Region key cannot be turned into one later (`kms.tf`, [ADR 70](decisions.md)) |
| | Least-privilege IAM | built, **narrower than the roadmap** | The api may generate and unwrap, the worker only unwrap, the other services nothing; on key ARNs (an alias does not grant); with the application's encryption context required. `Encrypt` and `DescribeKey` are not granted because nothing calls them. Tested per workload in `terraform test` |
| | Store the key reference | built | `KMS_KEY_ID` is the alias, rendered into the GitOps values from a Terraform output; the one secret (a wrapped master) is in Secrets Manager |
| 2 Rails setup | Option A: `active_kms` | **measured, not used** | Source and README read; run on Rails 8.1.4 against a counting client: 1 Encrypt + 1 Decrypt per create (its README says 3 + 1), 1 Decrypt per row read (101 rows, 101 requests), 4 Decrypts to save a record whose attribute was read, **no encryption context**, errors swallowed into "no key". And a deterministic attribute never reaches a configured provider in Rails 8.1, so the roadmap's own example would not have used KMS ([ADR 69](decisions.md)) |
| | Option B: Lockbox + `kms_encrypted` | considered, not used | Read: per-record keys and a context that can name the record, at the price of a second encryption stack beside the one in use and a KMS call per record read |
| | (built) | built | `gems/kms_encryption`: a provider with `GenerateDataKey`, a context, a bounded cache and typed failures; a deterministic provider that unwraps one master once; a local stand-in; three explicit key sources, none of which is a guess in production |
| 3 What to encrypt | User email | built | `users.email_address`, deterministic, so sign-in and the unique index work. 20 µs to encrypt, 72-91 bytes of overhead, and **no KMS request** on any lookup |
| | Phone, private notes, project credentials, task notes | n/a | **This schema has none of these.** Task text is visible to every member and is searched and embedded, so it is not encrypted; invitation addresses are not either, because the audit trail holds the same address in plaintext |
| | Integration tokens, webhook secrets | built | `webhooks.secret` moved from the credentials key to a KMS-wrapped key per value; old values still read and `kms:encrypt` moves them |
| | Migrate carefully, backfill in the background | built, **rehearsed** | `ENCRYPTION_ALLOW_PLAINTEXT` window with a mandatory close-by date that fails CI when it passes; `bin/rails kms:encrypt` in resumable batches; run end to end on a copy of the development database. **Found a Rails 8.1.4 bug** (extended queries plus `normalizes` made unconverted users unfindable) and worked around it narrowly |
| 4 Security practice | Encryption context | built, **cannot name the row** | Application, table, attribute. Rails gives a provider no record, and a new record has no id |
| | Separate permissions | built at workload level | Possible between the api and the worker, not within a process |
| | Never log decrypted values | existed + specs | Encrypted attributes are filtered; a spec checks that queries carry ciphertext |
| | A key per environment; alias over key id | built | Each environment has its own state and keys; the application uses the alias, IAM lists the keys |
| | CloudTrail on the key | built | A trail for **KMS events only**, with alarms on decrypt volume, refusals and key changes (`kms_audit.tf`) |
| 5 Testing | An insecure test key; no calls to AWS | built | `LocalClient` (a public key, refused in production); tests are forced onto it whatever the shell exports |
| | Encrypted at rest, decrypts, deterministic query | built | `encryption_spec`; plus stubbed SDK responses of AWS's documented shapes, and a run of the **real SDK against a KMS-compatible server** (moto) |
| 6 Rotation and operations | Automatic annual rotation | built | On for every key; an alarm if it is turned off |
| | Manual / emergency rotation | built, **never run** | `data_key_generations`: add a number, the alias moves in the same apply, the old key decrypts until `kms:verify` says nothing needs it, then it is removed ([runbook](runbooks/kms-key-rotation.md)). Rotating the master for addresses is its own procedure, and a spec found that Rails would have read old values and never moved them |
| | Monitoring | built, thresholds **chosen** | CloudWatch alarms on the trail, two Prometheus alerts (promtool-tested) on the application's own `taskapi_kms_requests_total` |
| | Cost awareness | arithmetic only | Requests per operation are known and measured; prices were **not** looked up ([kms.md](aws/kms.md#cost)) |
| 7 Advanced | Active Storage files | built | SSE-KMS with a bucket key; the replication rule opts in to KMS-encrypted objects (S3 would otherwise skip them silently) |
| | Active Job arguments | **audited: nothing to encrypt** | Every argument is a record (by id) or a timestamp; a spec fails if a job or mailer gains an address/token/secret parameter |
| | Per-organization keys | design only | Cost, quota, and it would not limit a compromised application; the cheap first step is the organization in the context ([ADR 70](decisions.md)) |
| | Data keys stored beside the data | built | That is the provider's design (the wrapped key travels in the value's header) |
| | Secrets Manager with KMS | built | A customer-managed key for the primary's secrets; a standby's replicas stay under that region's managed key |
| | Blind indexes | not built | Deterministic encryption answers equality, the only query on addresses |
| **One click** | Run Terraform from CI, by hand, all at once | built, **never run** | `.github/workflows/provision.yml`: `workflow_dispatch` only; plan, summary, apply *that* plan; no stored AWS key; `apply`/`destroy` from `main`, `destroy` confirmed by name; a one-time CloudFormation bootstrap for the role and state bucket ([ADR 71](decisions.md), [one-click.md](aws/one-click.md)) |
| **Found on the way** | `rack` 3.2.7 had four published advisories | fixed | `bundler-audit` failed on `main`'s lockfiles (the app and all three services); updated to 3.2.8, a patch release |
| | A real defect in my first rotation design | fixed | The unit spec showed that after reading through the previous master and calling `encrypt`, nothing changed: Rails keeps writing a *fixed* deterministic attribute with its oldest scheme. The macro now sets `fixed: false` while previous masters are configured |
| | A mutation harness that could not fail | fixed | The first Terraform mutation run reported 31 of 31 killed in three seconds each because the copy lacked `deploy/lambda`; the unmutated copy failed too. The harness now refuses to start unless its baseline passes |

## Roadmap 8: Only the owner reaches AWS

*Goal: "harden the GitHub configs to allow only myself to deploy and test on AWS resources". There was no checklist: the first step was to read what could reach AWS and from whom (the workflows, the two trust policies, and GitHub's live settings through the API), then close what was open. Decision record: [ADR 72](decisions.md).*

| Item | Status | Implemented as |
| --- | --- | --- |
| Audit: who has access | clean | Public repository, one collaborator, no deploy keys, webhooks, invitations, Actions secrets or variables; secret scanning and push protection already on; the default token already read-only |
| A fork's pull request could start `deploy.yml` | fixed (**reasoned, not demonstrated**) | `workflow_run` runs with the repository's permissions, and its `branches: [ main ]` filter matches the triggering run's branch *name*. The build job now requires a push, to this repository, to `main`, by the owner; the field names and types were checked against a real CI run |
| The AWS roles could not have been assumed by this repository | **fixed; a defect in roadmap 7** | The repository was made after 2026-07-15, so its tokens carry the owner's and repository's IDs; both trusts (the bootstrap role and `github.tf`) wrote names. Read from `GET .../oidc/customization/sub`. Now one subject, `StringEquals`, with GitHub's own prefix: a required, pattern-checked bootstrap input, and for Terraform read by the Provision workflow from its own token |
| The deploy role also trusted any run on `main` | fixed | Environment only |
| Environments | **applied to the real repository**, read back | `dev` had no protection and administrators could bypass; the other four would have been created unprotected on first use. All five: deployment branch `main` only, the owner as required reviewer on `staging`, `staging-dr`, `prod`, `prod-dr` (not `dev`), administrators cannot bypass |
| Provision AWS | built | First step refuses any account but the owner, including a re-run by someone else; a step that prints the token's claims and hands Terraform its subject prefix; actions pinned to commits; no repository token left on disk |
| `deploy.yml` | built | Empty permissions by default; the AWS token only on the build job, write access only on the job that commits the tag; actions pinned; the build's checkout keeps no token |
| Fork pull requests | **applied** | Approval needed from every outside contributor, every time (was: first-time contributors) |
| `CODEOWNERS` | built | The owner for everything, and for `.github/` and `deploy/` by name |
| Keeping it so | built | `deploy/scripts/github_settings.rb`: the wanted settings as data; read-only check by default (exit 1 on drift), `--apply` to fix; reports, and never changes, who has access and whether `main` refuses force pushes and deletion |
| The owner in the token's subject (`actor_id`) | **not built** | GitHub's documentation does not say the key is accepted or how it renders. The Provision workflow now prints a real token's claims, which is the evidence to decide on |
| Enforce rules for administrators, required status checks on `main` | **not changed** | With one maintainer and a required review it would lock the owner out of their own pull requests. The script reports it |
| A private repository | not done | Removes strangers' pull requests entirely; this repository is a public portfolio |
| **Found on the way** | `deploy.yml` fails on every merge to `main` today | Expected until `AWS_DEPLOY_ROLE_ARN` exists (nothing is applied); not changed |

## Next

What is left, ordered by what a real user would hit first. Each of these needs something this repository cannot supply (an AWS account, a host, a browser, a client, or evidence), which is why they are here and not done.

1. **Apply the staging pair and run the first drill** ([runbook](runbooks/failover-drill.md)), then production's once a single region has run for a few months and an RTO/RPO is stated ([design](aws/multi-region.md#building-it-in-this-order)). Everything it needs is written; what is missing is an account and an afternoon.
2. **If cross-project search ever becomes the slow endpoint**, require a project (or a short list) for a broad query, or add an index that answers "newest matches first" across projects. Capping the ranking was measured and does not help there ([ADR 50](decisions.md)).
3. **More GraphQL mutations** (projects, memberships, tags, ...) and **subscriptions**, one at a time, when a client needs them ([ADR 51](decisions.md)); REST and Action Cable already cover both.
4. **Hosting the demo** (`demo/web/build.sh`, then `bin/kamal setup -d demo`; [docs/demo.md](demo.md)), and **looking at the front end in a browser**: its layout has never been seen.
5. **Run game day experiment E7** (fail over the Aurora writer) in staging ([failure-domains.md](architecture/failure-domains.md)). Every claim about the database depends on how long writes fail and whether pods reconnect, and it has never been measured.
6. **Secret scanning in CI**, and **webhook signing-secret rotation with an overlap window** (sign with both secrets for a while). The two open items in the threat model that cost the least.
7. **Close the erasure across services**: events through the outbox, the Auth service deleting by subject, the Notification service storing a recipient id so it can delete by id ([design](architecture/boundaries.md#a-saga-that-exists-erasing-a-person-across-services)). Needed the day JWT mode has real users.
8. **Decide the audit trail's retention** (a policy question, not a technical one) and, if it is anything shorter than for ever, partition it by month ([plan](architecture/data-lifecycle.md#archival-audit-events-when-it-is-time)).
9. **Replace the AI service's shared token** with the caller's service-account token ([threat-model.md](threat-model.md), T15).
10. **Project ownership transfer**, so that erasing an owner is one step.
11. **Apply the KMS stack and run a real `plan`** (the bootstrap in dev, then **Provision AWS** with `plan`), then game day **E11** (take the api role's `kms:Decrypt` away for ten minutes). Every claim about KMS latency, throttling, key policy evaluation, CloudTrail's record shape and replication with KMS is unmeasured ([kms.md](aws/kms.md#not-verified)). Read `TaskApi/KMS DecryptRequests` for a few weeks, then set `kms_decrypt_alarm_threshold`.
12. **Encrypt the other copies of an address**: the audit trail (a policy decision: encrypt or hash), the outbox payload, and the Auth and Notification services, which hold addresses of their own and could use the same gem. Until then [kms.md](aws/kms.md#what-is-encrypted) lists them.
13. **A key per record in the context** (Lockbox-style), only if per-record audit or per-tenant keys become a requirement ([ADR 70](decisions.md)).
14. **Run Provision AWS with `plan` in `dev` and read the identity table in its first step.** It is the first real evidence for the Environment subject's spelling and for every claim ADR 72 makes about GitHub. If the token carries what is inferred, consider putting the owner's ID in the subject so AWS itself refuses anyone else; and decide on required status checks for `main`.
15. **Dependabot's five open pull requests (#14, #16-#19) edit the action lines now pinned to commits**; ask it to recreate them after this merges (`@dependabot recreate`), and it will propose the pinned form.

## How this was verified

| Claim | Evidence |
| --- | --- |
| The application behaves as documented | 1,507 examples across the app, shared gems and Lambdas (+78 in the three services), run with branch coverage under `CI=true` (93.7% line, 83.7% branch; floors 92/81); 32 Node tests for the demo front end; 26 `terraform test` runs |
| Search, deep paging and the inbox are fast | `EXPLAIN (ANALYZE)` and in-process timings on a 149,000-task database, 300,000 synthetic notifications ([performance.md](performance.md), the ADRs) |
| The outbox loses nothing | specs: rolled-back changes leave no event; a failing SNS keeps the event and delivers it exactly once when it returns; two relays never send the same row (including from four threads); a request through to a stubbed SNS |
| Access is as documented | `tenant_isolation_spec` (every route, now including teams, invitations, search, the inbox, GraphQL), `project_policy_team_spec` (both role lookups agree for every combination), `graphql_spec` ("who can see what") |
| The load-test script works | `loadtest/ci.sh` ran locally end to end: a passing run, and a deliberately overloaded one that exited 99, listed the breached thresholds and cleaned up |
| Backups restore | `pg_dump` → `pg_restore` of the same database; row counts, constraints and the `vector` extension checked |
| The multi-region wiring is right | `terraform test` (in CI): the whole configuration is planned and applied against mocked AWS providers for a single region, a primary before and after its standby is ready, and a standby; mutation-checked ([ADR 45](decisions.md)). Proves what each role creates, not that AWS accepts it |
| Read-only mode keeps reads working | run against a Postgres that really refuses writes (`default_transaction_read_only`) and against `READ_ONLY=true` on a live server: reads 200, writes 503 `read_only`, nothing written; mutation-checked ([ADR 46](decisions.md)) |
| The backup scripts and the failover probe work | `db_dump.sh` / `db_restore_check.sh` on the 149,000-task database (7 MB, restored in 4 s); `drill_probe.rb` against a live server restarted into read-only mode and back; specs for both, mutation-checked |
| The activity feed and audit logs scale | 1,000,000 audit events in one project and 1.14 million across eight: offset 23-131 ms (feed 110-270 ms), cursor 0.6 ms, `ActivityFeed` 1.3 ms; identical results to the single query ([ADR 50](decisions.md)) |
| Mutations and teams cannot be used to see or change what REST would refuse | `graphql_mutations_spec` (same input through both APIs, every policy consulted, eleven breakages caught), `project_policy_team_spec` (both role lookups agree, nested), 5 + 9 breakages of the team rules caught |
| The demo front end works | 32 Node tests in CI; the real client against a live demo server; the real `app.js` driven in jsdom against it (once, outside this repository); CORS preflights from its origin |
| Migrations are safe | `strong_migrations` accepted every migration but one: the full-text column, which rewrites `tasks` under a lock (3.7 s for 149,000 rows) and is marked `safety_assured` with that number ([runbook](runbooks/zero-downtime-migrations.md)) |
| Idempotency, sparse fieldsets, replica routing, load handling, sessions, erasure and retention behave as documented | request, model, job and service specs for each; every item was mutation-checked (deliberate breakages of the code, each of which must fail a test). Several survivors pointed at real gaps: a redundant line, an unasserted effect, a loop nobody tested |
| The retention purge is cheap | 1,000,000 webhook deliveries, 35% expired, oldest rows at the highest ids (worst case for the query): 1.27 s in batches of 5,000, no new index |
| The SLO and scrape alerts fire when they should | `promtool test rules` against synthetic series, mutation-checked; plus a spec that the PodMonitor sends the token the API demands, by reading the chart values and (with `helm`) rendering it. **Not** a scrape of a real API |
| Encrypted columns behave as documented, and cost what ADR 69 says | `encryption_spec`, `encryption_inventory_spec`, the gem's 54 examples and the rake-task specs pin the request counts (create a webhook: 1 `GenerateDataKey`, 0 `Decrypt`; any number of reads and saves of a cached key: 1; every lookup and sign-in: 0). The same numbers were then **measured through the real `aws-sdk-kms` client against a KMS-compatible server** (moto), alongside how its real errors are classified. Measured: 20 µs to encrypt an address, 9 µs to decrypt, 72-91 bytes of overhead; the third-party provider's request counts on Rails 8.1.4 |
| A plaintext column can be converted without downtime | **Rehearsed** on a copy of the development database (6 users): sign in during the window (including an address typed with other case and spaces), register during it, `kms:encrypt`, `STRICT=1 kms:status`, close the window, sign in again; no readable address left. The rehearsal found the Rails bug in ADR 69 |
| The Ruby and workflow changes cannot be quietly undone | Mutation-checked: well over a hundred deliberate breakages (the exact count was not kept) of the gem, the application wiring, the transition workaround, the rake tasks, the workflow, the bootstrap stack, the Prometheus alerts and the Terraform, each of which fails a test (one is a performance-only equivalent). The survivors found real gaps: the credentials-key fallback after removal, the context's table, per-column master keys, `ready?` on Rails' own keys, a rotation that wrote with the oldest master, an inventory that counted anonymous classes, an unchecked plan-time address, and External Secrets' grant on the secrets key |
| The Terraform for keys, grants, replication and the audit trail is as described | `terraform test`: 12 new runs against mocked providers for a single region, a primary, a standby, a rotation to a second generation, every switch off, and replication with and without KMS; 31 deliberate breakages of the Terraform in a copy: 30 failed a test at once; **one survived** (nothing tested that External Secrets may decrypt the secrets key, without which no ExternalSecret syncs and no pod starts), which is now tested at two levels and killed. The first attempt at this run was invalid (see the ledger) and was thrown away |
| The workflow and its bootstrap stack are well formed | `actionlint` (now also in CI), `cfn-lint` (now also in CI), 21 specs that pin what the workflow must never do (run by itself, hold a key, apply from a branch, destroy unconfirmed, paste an input into a shell), and the stack created in moto. **Not** run on GitHub or in AWS |
| The KMS alerts fire when they should | `promtool test rules` against synthetic series (now also in CI), mutation-checked |
| The table-to-tenant map is complete | `spec/db/tenant_ownership_spec.rb` fails on a table with no owner or a column that is not a foreign key |
| **Not verified** | Docker Compose, `kind`, any Terraform plan/apply against a real account (the multi-region pair, the staging pair and the backup copy are checked only offline, against mocks), AWS Backup, the real `aws` and `age`, a failover drill of any kind, how the demo front end looks in a browser, Kamal deploys (the demo destination only passes `kamal config`), Bedrock with real credentials, the Aurora restore commands, hosting the demo; **everything in roadmap 6 that touches AWS or a cluster**: the read replica on Aurora, the Helm and Terraform changes beyond `helm template` and `terraform test`, `kubeconform` on the new PodMonitor, a real Prometheus scraping the API, the secrets-rotation procedures, the FIS experiments, and every game-day experiment; **everything in roadmap 7 that touches AWS or GitHub**: every KMS call to real KMS (latency, throttling, the quota, the size of a real wrapped key), the key and bucket policies, `aws_kms_replica_key`, S3 replication with KMS, CloudTrail's record shape under the metric-filter patterns, the bootstrap stack and the **Provision AWS** workflow on real runners, the rotation procedures, and conversion at production size. The alarm thresholds (2,000 Decrypts per five minutes; 2 requests a second) are chosen, not observed |
