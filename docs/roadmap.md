# Roadmap and implementation record

What was planned, what was built, where it lives, and what was deliberately left. Three roadmaps have been worked through, in order;
each section is a ledger, not a plan, so every line says what actually happened.

| # | Roadmap | Delivered in | Result |
| --- | --- | --- | --- |
| 1 | [Build an API-only Rails 8.1 backend](#roadmap-1-build-the-api) (phases 0-7) | [#1](https://github.com/AravindRajeshkanna/rails-task-api/pull/1) | The Task/Project Management API |
| 2 | [AI-powered, AIOps-enabled microservices on AWS EKS](#roadmap-2-ai-aiops-and-microservices-on-eks) (phases 1-6) | [#5](https://github.com/AravindRajeshkanna/rails-task-api/pull/5) | AI features, observability, three extracted services, the platform to run it |
| 3 | [Improve it further](#roadmap-3-improving-the-project-further) (phases 1-8) | this change | Hardening, testing, performance, security, documentation, organizations, analytics |

**Status key.** ✅ done and verified as described · 🟡 done in part, or done differently on purpose (the note says how) · ⏭ deliberately not done (the note says why, and what would trigger it).

**What "verified" means here.** The application code is covered by specs that run in CI. The platform code (Docker Compose, `kind`,
Terraform, Helm, Argo CD, Kamal) is validated statically and by CI (images build, Terraform validates, Helm renders and passes schema
checks) but **has never been applied to AWS or run under Docker/Kubernetes**. The AI features run against the offline provider; **Bedrock has
not been called**. Those boundaries are repeated where they matter.

The reasoning behind the non-obvious choices is in [decisions.md](decisions.md) (ADRs 1-34); user-visible changes are in [../CHANGELOG.md](../CHANGELOG.md).

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
| 7 Polish & portfolio | Soft delete, auditing, webhooks, GraphQL (optional), multi-tenancy, README, ADRs, public demo | 🟡 | Soft delete + restore, append-only audit log ([ADR 11](decisions.md)), signed SSRF-guarded webhooks ([ADR 10](decisions.md)), README, ADRs ✅. Multi-tenancy: now organizations (roadmap 3). **GraphQL ⏭** (optional, no consumer needs it). **Public demo ⏭** (nothing deployed; deployment is yours to run) |

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

*Goal: take the project from a solid learning build to a production-ready portfolio piece, in eight phases. Delivered in this change.*

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
| ADR document | ✅ | [decisions.md](decisions.md): 1-13 (#1), 14-28 (#5), 29-34 (this change) |

### Phase 2: Testing

| Planned | Status | Implemented as |
| --- | --- | --- |
| High coverage on critical paths | ✅ | SimpleCov line and branch: 92.8% / 82.1%; policies, models and controllers at 96-100% ([testing.md](testing.md#coverage)) |
| Request specs for every endpoint | ✅ | rswag + request specs; `api_docs_spec` fails on an undocumented route; `tenant_isolation_spec` fails on a route with no isolation decision |
| Model + policy specs | ✅ | `spec/models`, `spec/policies` (including organization access and role matrices) |
| FactoryBot + Faker + Shoulda | ✅ | In place since #1 |
| Integration tests for auth flows | ✅ | `authentication_spec` (pieces) and `authentication_journey_spec` (sign up → work → reset password → signed out everywhere) |
| VCR or WebMock | 🟡 | WebMock ✅. VCR deliberately not added: outbound calls are webhooks and AWS SDK calls, which stub cleanly without cassettes that record real responses ([testing.md](testing.md#decisions)) |
| SimpleCov with a CI floor | ✅ | `COVERAGE=1`; floor 91% line / 79% branch in `spec/spec_helper.rb`; CI uploads the report and prints it in the job summary |
| Parallel testing if the suite grows | ⏭ | 736 examples run in ~10 s; parallelism would add cost for no gain. Trigger: suite past ~2 minutes ([testing.md](testing.md#decisions)) |
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
| Activity feed / notifications | 🟡 | Activity feed: `GET /activity`, the member's view of the audit log across their projects. Email and Slack notifications via the Notification service (#5). **An in-app notification inbox (read/unread) ⏭**: it needs per-user read state and a fan-out design |
| File attachments (Active Storage + S3) | ✅ | Local disk, or S3 with `ACTIVE_STORAGE_SERVICE=amazon` (#5) |
| Advanced search | 🟡 | Trigram-indexed title search and substring search (#1); semantic similar-task search with pgvector (#5). Full-text (`tsvector`/pg_search/OpenSearch) **⏭**: text search is the slowest read (27 ms on a 50k-task project); trigger: it shows in a p95 |
| Webhooks | ✅ | #1 |
| Multi-tenancy | ✅ | Organizations are the tenant boundary: a project belongs to one for life and only takes its members ([ADR 34](decisions.md)). Row-level security / schema-per-tenant ⏭, not needed at this scale |
| Real-time updates | ✅ | Solid Cable `ProjectChannel` (#1) |
| AI features | ✅ | #5 |
| Usage analytics dashboard | ✅ | `GET /projects/{id}/analytics`: counts, throughput per period, cycle time (median/p90), workload. Backend only; no UI in this repository |
| RBAC with teams/organizations | 🟡 | Organizations with `owner`/`admin`/`member`, admins administering all org projects, last-owner and removal rules; policy, model and request specs. **Teams ⏭** (sub-groups with their own project access): the next step when per-team access is needed |

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
| Multi-region or advanced AWS | 🟡 | Advanced AWS in place (Karpenter, Pod Identity, WAF, FIS, Budgets). **Multi-region ⏭**: it cannot be validated without an AWS account, and unvalidated Terraform for failover is a liability. The design is below |

---

## Next

Ordered by what a real user would hit first. None is started.

1. **An invitation flow.** Members are added by the email of an existing user, so an admin can probe whether an address is registered.
   Fix: invite by email (a token the invitee redeems), the same answer whether or not the address exists. Closes a known gap in [security.md](security.md).
2. **Audit organization changes.** Project and task changes are audited; role changes in an organization are not. `AuditEvent.project_id` is nullable; add an organization column and a feed for owners.
3. **Teams** inside organizations, as a second kind of principal on project memberships, after (1) and (2).
4. **Full-text search** (`tsvector` generated column + GIN, `websearch_to_tsquery`, ranked) when text search shows in a p95; cross-project search endpoint.
5. **In-app notification inbox** with read state, fed by the same events the Notification service consumes.
6. **Keyset pagination** for the task list once any project passes ~1 million rows (offset 10,000 costs 3.5 ms today).
7. **Transactional outbox** for events (today they are published after commit through a job; a long SNS outage loses events: [README](../README.md#known-limitations)).
8. **A load test in CI** against an ephemeral environment (nightly), failing on the thresholds in `loadtest/k6/api.js`.
9. **Multi-region.** Sketch: Aurora Global Database (secondary region read-only, promote on failover), Route 53 failover records with health checks, S3 cross-region replication and ECR replication, a second EKS cluster added through the ApplicationSet cluster generator, and the SNS topics mirrored per region. Do this only after a single region has run in anger.
10. **GraphQL** and a **public demo** (optional items from roadmap 1) when there is a consumer.

## How this was verified

| Claim | Evidence |
| --- | --- |
| The application behaves as documented | 736 examples across the app, shared gems and Lambdas (+72 in the three services), run with branch coverage in CI |
| Queries are fast and the index matters | `EXPLAIN (ANALYZE)` and k6 on a 149,000-task database, production mode ([performance.md](performance.md)) |
| Backups restore | `pg_dump` → `pg_restore` of the same database; row counts, constraints and the `vector` extension checked |
| Migrations are safe | `strong_migrations` accepted all six new migrations without `safety_assured` |
| **Not verified** | Docker Compose, `kind`, any Terraform plan/apply, Kamal, Bedrock with real credentials, the Aurora restore commands |
