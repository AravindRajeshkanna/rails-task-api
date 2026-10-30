# Task API

A task and project management **JSON API** built on **Rails 8.1** (API-only), Ruby 4.0 and PostgreSQL.
Users sign up, create projects, invite teammates, and manage tasks with comments, tags, file attachments,
real-time updates and signed webhooks.

It is also a worked example of "modern Rails": the Solid stack instead of Redis, the built-in authentication
and rate-limiting primitives, structured events, Active Job continuations, and Kamal 2 deploys.
The reasoning behind each non-obvious choice is in [docs/decisions.md](docs/decisions.md).

It has since grown into an **AI-powered, observable, microservice platform for AWS EKS**: natural-language task
creation, AI summaries and suggestions, three extracted services (Auth, AI, Notifications), OpenTelemetry/Prometheus/CloudWatch
observability with anomaly alarms and an AIOps loop, and Terraform + Helm + Argo CD to run it. Start with
[docs/architecture/overview.md](docs/architecture/overview.md); to deploy, follow [docs/aws/setup-guide.md](docs/aws/setup-guide.md).

- **Interactive docs:** run the server and open <http://localhost:3000/api-docs> (OpenAPI 3, generated from the specs)
- **Spec:** [swagger/v1/swagger.yaml](swagger/v1/swagger.yaml) · **What changed for clients:** [CHANGELOG.md](CHANGELOG.md)
- **What was built, in which pull request, and what comes next:** [docs/roadmap.md](docs/roadmap.md)

## What's in it

| Area | Implementation |
| --- | --- |
| Resources | Users, Organizations (invitations, teams, audit log), Projects, Memberships, Tasks, Comments, Tags, Webhooks, Audit events, Activity, Analytics, Notifications (inbox), Search |
| Auth | Bearer-token sessions (digest-only storage), sign-up, sign-in/out, password reset |
| Authorization | Pundit policies; project roles `member` / `admin`; owner-only deletes; organizations (`owner` / `admin` / `member`) whose owners and admins administer all of their projects, and whose projects only take their members; teams a project can grant a role to; access resolved in the policies, never copied |
| API design | `/api/v1` namespace, shallow routes, [Alba](https://github.com/okuramasafumi/alba) serializers, [Pagy](https://github.com/ddnexus/pagy) pagination, filtering / sorting, substring and ranked full-text search, offset and cursor pagination, a read-only GraphQL endpoint, one error envelope |
| Hardening | `rack-cors`, `rack-attack` + Rails 8 `rate_limit`, `secure_headers`, optimistic locking, SSRF-guarded webhooks, database CHECK constraints, a tenant-isolation sweep over every route ([docs/security.md](docs/security.md)) |
| Background work | Solid Queue: assignment & reminder emails, webhook delivery with retries, retention purge; a transactional outbox relays events to SNS |
| Real time | Solid Cable: `ProjectChannel` pushes task and comment events |
| Storage | Active Storage: user avatars, task attachments (type and size validated, signed short-lived URLs) |
| Caching | Solid Cache: per-project task statistics, invalidated by `touch` |
| Rails 8.1 | `Rails.event` structured events, `ActiveJob::Continuable`, `bin/ci` local CI |
| Data safety | Soft delete + restore, 30-day purge, append-only audit log |
| AI | Bedrock (Converse + Titan embeddings) or an offline fake: create tasks from sentences, priority and deadline prediction, tags, assignee suggestions, project summaries, a tool-using chatbot. Validated output, per-user token budgets, pgvector search, an evaluation harness ([docs/architecture/ai.md](docs/architecture/ai.md)) |
| Observability | Structured events as JSON logs, Prometheus `/metrics`, OpenTelemetry → X-Ray, CloudWatch anomaly alarms, SNS → PagerDuty/Slack ([docs](docs/architecture/observability-and-aiops.md)) |
| Services | Auth (JWT, rotating refresh tokens), AI, Notifications (SQS consumer), events as CloudEvents on SNS/SQS ([docs](docs/architecture/microservices.md)) |
| Platform | Docker Compose, `kind`, one Helm chart, Terraform (EKS, Karpenter, Aurora, SNS/SQS, WAF), Argo CD + Rollouts, KEDA, AIOps Lambdas ([deploy/](deploy/README.md)) |
| Quality | RSpec (1,036 across the app, shared gems and Lambdas, with a line/branch coverage floor; 72 more in the services), Bullet raising on N+1, RuboCop with the Lint/Rails/Performance cops, Brakeman, bundler-audit, `strong_migrations`, `terraform validate`, Kubernetes schema checks ([docs/testing.md](docs/testing.md)) |
| Performance | Measured, not guessed: `EXPLAIN` on 149k tasks, k6 load tests (nightly in CI), evidence-based indexes ([docs/performance.md](docs/performance.md)) |
| Delivery | Dockerfile, Kamal 2 config (single host), EKS via GitOps (below), GitHub Actions, JSON logs, `/up` health check, optional Sentry |

## Quick start

**Prerequisites:** [mise](https://mise.jdx.dev) (or any Ruby manager) and PostgreSQL 15+.

```bash
# macOS
brew install mise postgresql@17 libpq
brew services start postgresql@17        # or: pg_ctl -D /opt/homebrew/var/postgresql@17 start

mise install                             # Ruby 4.0.9, pinned in mise.toml
bundle install
bin/rails db:prepare                     # creates, migrates and seeds a fresh database
bin/dev                                  # http://localhost:3000
```

Seed data is a demo account, `demo@example.com` / `password123` (`bin/rails db:seed` re-runs it safely; it refuses to run in production).
The development database connects over the local Unix socket as your OS user (the Homebrew default).
Elsewhere, create a role first: `createuser -s $USER`.

Try it:

```bash
TOKEN=$(curl -s localhost:3000/api/v1/session -H 'Content-Type: application/json' \
  -d '{"email_address":"demo@example.com","password":"password123"}' | jq -r .data.token)

curl -s localhost:3000/api/v1/projects -H "Authorization: Bearer $TOKEN" | jq

# Urgent or high priority tasks in project 1, most urgent first, then by due date
curl -s "localhost:3000/api/v1/projects/1/tasks?priority=urgent,high&sort=-priority,due_on" \
  -H "Authorization: Bearer $TOKEN" | jq '.data[] | {title, priority, due_on, overdue}'
```

## API conventions

**Authentication.** `POST /api/v1/registrations` or `POST /api/v1/session` returns a token (valid 30 days).
Send `Authorization: Bearer <token>`. `DELETE /api/v1/session` revokes it.

**Envelope.** Successful responses are `{ "data": ..., "meta": ... }`; request bodies are flat JSON
(`{"title": "..."}`). Timestamps are ISO 8601 in UTC.

**Errors.** Every failure has the same shape, including routing errors and malformed JSON:

```json
{ "error": { "status": 422, "code": "validation_failed", "message": "Validation failed",
             "details": { "title": ["can't be blank"] } } }
```

| Status | `code` | When |
| --- | --- | --- |
| 400 | `parameter_missing`, `invalid_parameter` | Missing field; bad filter / sort / date value (`details.parameter` names it) |
| 401 | `unauthenticated`, `invalid_credentials` | No / bad / expired token; wrong password |
| 403 | `forbidden` | You can see the resource but your role may not do this |
| 404 | `not_found` | Missing **or not yours**: resources in projects you don't belong to look nonexistent |
| 409 | `stale_object`, `conflict` | `lock_version` out of date; uniqueness race |
| 422 | `validation_failed` | Details are keyed by field |
| 429 | `rate_limited` | Honour `Retry-After` |
| 503 | `read_only`, `ai_unavailable`, `ai_not_configured` | `read_only`: a database promotion or maintenance is under way. Reads work, nothing was changed, retry the write after `Retry-After` |

**Rate limits** (`429` + `Retry-After`): sign-up 10/hour per IP; sign-in and password reset 10 per 3 minutes per IP, and
5 sign-ins per minute per account; everything under `/api` 300 per 5 minutes per IP and 600 per 5 minutes per token.

**Pagination.** `?page=2&limit=50` (default 25, max 100). The body has `meta` (`page`, `limit`, `count`,
`pages`, `next`, `previous`) and responses carry `Link` (RFC 8288), `Total-Count`, `Total-Pages`,
`Current-Page` and `Page-Limit` headers.

**Cursor pagination** (optional, for long task lists). `GET /projects/:id/tasks?cursor=` returns the first page, and `?cursor=<meta.next_cursor>`
the following ones (`meta` is `{limit, next_cursor, has_more}`; `Link` has `rel="next"`; there is no total). Unlike `page=`, a page costs the same at any depth
and no task is skipped or repeated when others are added meanwhile. It works with every filter, and with sorts by `created_at`, `updated_at` and `title`
(not relevance, `priority`, `status` or `due_on`); use the cursor with the filters and sort that produced it.

**Task filters** (`GET /api/v1/projects/:id/tasks`, all combinable):
`status`, `priority` (comma lists), `assignee` (`me` / `unassigned` / id), `tag`, `due_from`, `due_to`,
`overdue=true`, `q` (substring search of title and description), `search` (full-text: stemmed words, `"phrases"`, `or`, `-excluded`; best match first unless `sort` is given), `sort` (`-priority,due_on`; prefix `-` for descending).
`GET /api/v1/search?q=` is the same full-text search across every project you can see, with highlighted snippets (matches wrapped in `«»`).

**Optimistic locking.** Tasks expose `lock_version`; send it back on `PATCH` and a concurrent edit returns `409`.

**Soft delete.** `DELETE` on projects and tasks hides them; `POST .../restore` brings them back. They are
purged for good after 30 days.

### Endpoints

| | |
| --- | --- |
| Auth | `POST /registrations` · `POST /session` · `DELETE /session` · `POST /passwords` · `PATCH /passwords/:token` |
| Account | `GET` `PATCH /me` · `PUT` `DELETE /me/avatar` |
| Organizations | `GET` `POST /organizations` · `GET` `PATCH` `DELETE /organizations/:id` · `GET /organizations/:id/members` · `PATCH` `DELETE /organizations/:id/members/:member_id` · `GET` `POST /organizations/:id/invitations` · `DELETE /organizations/:id/invitations/:id` · `POST /invitations/accept` · `GET /organizations/:id/audit_events` (owners) · `GET` `POST /organizations/:id/teams` · `GET` `PATCH` `DELETE /organizations/:id/teams/:id` · `GET` `POST /organizations/:id/teams/:id/members` · `DELETE /organizations/:id/teams/:id/members/:member_id` |
| Projects | `GET` `POST /projects` (`organization_id` creates one inside an organization) · `GET` `PATCH` `DELETE /projects/:id` · `POST /projects/:id/restore` |
| Members | `GET` `POST /projects/:id/memberships` · `PATCH` `DELETE /memberships/:id` · `GET` `POST /projects/:id/teams` · `PATCH` `DELETE /projects/:id/teams/:id` (a team's access) |
| Inbox | `GET /notifications` (`unread`, `project_id`, `kind`) · `PATCH` `DELETE /notifications/:id` · `POST /notifications/read_all` · live over `NotificationsChannel` |
| GraphQL | `POST /graphql`: read-only, same access rules ([docs/graphql](docs/graphql/README.md)) |
| Search | `GET /search?q=` (all your projects) · `GET /projects/:id/tasks?search=` (one project) |
| Tasks | `GET` `POST /projects/:id/tasks` · `GET` `PATCH` `DELETE /tasks/:id` · `POST /tasks/:id/restore` |
| Comments | `GET` `POST /tasks/:id/comments` · `PATCH` `DELETE /comments/:id` |
| Attachments | `POST /tasks/:id/attachments` (multipart `files[]`) · `DELETE /attachments/:id` |
| Tags | `GET` `POST /projects/:id/tags` · `DELETE /tags/:id` |
| Webhooks | `GET` `POST /projects/:id/webhooks` · `GET` `PATCH` `DELETE /webhooks/:id` · `GET /webhooks/:id/deliveries` |
| Audit | `GET /projects/:id/audit_events` (admins) |
| Activity | `GET /activity` (everything that happened in your projects) |
| Analytics | `GET /projects/:id/analytics?from&to&interval` |

All paths are under `/api/v1`. Full parameter and schema detail: `/api-docs`.

### Roles

| | member | admin | owner |
| --- | :-: | :-: | :-: |
| View project, create & edit tasks, comment, tag | ✓ | ✓ | ✓ |
| Delete own tasks / comments | ✓ | ✓ | ✓ |
| Delete any task or comment, restore tasks | | ✓ | ✓ |
| Edit project, manage members, webhooks, audit log | | ✓ | ✓ |
| Delete / restore the project | | | ✓ |

Owners and admins of the project's **organization** count as project admins without being added to it; organization owners may also delete and restore its projects.
Within an organization: `owner` does everything (and is the only one who can grant `admin`/`owner` or delete it), `admin` adds and removes plain members,
`member` can create projects there. Details: [decision 34](docs/decisions.md).

### Real time

Connect to `/cable` with `Authorization: Bearer <token>` (or `?token=` from a browser) and subscribe:

```js
{ command: "subscribe", identifier: JSON.stringify({ channel: "ProjectChannel", project_id: 1 }) }
```

You receive `{ event: "task.updated", occurred_at, data: { ...task... } }` for `task.*`, `comment.created`
and `project.*` events. Only members of a non-deleted project can subscribe.

### Webhooks

Project admins register an `https://` URL and optionally a list of events (empty = all). Each delivery is a
JSON `POST` with these headers:

```
X-TaskApi-Event: task.completed
X-TaskApi-Delivery: 42
X-TaskApi-Timestamp: 1793236800
X-TaskApi-Signature: sha256=<hex>      # HMAC-SHA256(secret, "<timestamp>.<raw body>")
```

Verify the signature with the secret returned **once** at creation and reject old timestamps to stop replays.
Failures retry up to 6 times with growing delays; every attempt is visible at `GET /webhooks/:id/deliveries`.
Targets that resolve to private, loopback or link-local addresses are refused.

## Architecture

The pieces and how they fit are in [docs/architecture/overview.md](docs/architecture/overview.md). The monolith's layout:

```
app/
  controllers/api/v1/   thin controllers: authorize → query → serialize
  controllers/concerns/ Authentication (bearer), ErrorHandling (envelope), Pagination (Pagy)
  policies/             Pundit: who may do what, and the scopes that hide other tenants' rows
  resources/            Alba serializers (response shape lives here, not in models)
  queries/              TaskQuery: allow-listed filters and sorting
  models/               validations, scopes; concerns: Discardable, Auditable, EventEmitting
  subscribers/events/   react to domain events: log, broadcast (Cable), webhooks
  services/             EventPayload, Webhooks::*, Ai::* (AI layer), Events::* (CloudEvents/SNS),
                        Observability::*, ExternalAuth
  jobs/ mailers/ channels/
gems/
  ai_core/              provider-agnostic inference (shared with services/ai)
  service_kit/          JWT verification, JSON logs, metrics, tracing for services
services/               auth/ ai/ notifications/ (each its own Rails app, specs and Dockerfile target)
deploy/                 terraform/ helm/ gitops/ k8s/ observability/ lambda/ docker/ local/
docs/                   decisions.md, architecture/, aws/setup-guide.md, runbooks/
```

### Ways to run it

| Mode | Command |
| --- | --- |
| The monolith alone (auth local, AI offline) | `bin/rails s` |
| The whole architecture on Docker | `cp .env.example .env`, set `RAILS_MASTER_KEY` and `AUTH_JWT_PRIVATE_KEY`, then `docker compose up --build` (gateway on :8080, mail on :8025) |
| On a local Kubernetes cluster | `deploy/local/up.sh` (needs `kind`, `kubectl`, `helm`) |
| AWS | [docs/aws/setup-guide.md](docs/aws/setup-guide.md) |

A change flows like this:

```
PATCH /tasks/7 ─► authorize (Pundit) ─► model.update!
                                          ├─ Auditable   → AuditEvent row (same transaction)
                                          └─ EventEmitting → queued, published after COMMIT
                                                 │
                                       Rails.event "task.completed"
                         ┌───────────────────┼───────────────────┐
                   LogSubscriber    BroadcastSubscriber    WebhookSubscriber
                   (log line)       (ProjectChannel)       (WebhookDelivery + job)
```

Multi-tenancy: the **project** is the tenant boundary. Every child resource is reached through a policy
scope joined to the caller's memberships in non-deleted projects, so a missing membership is a `404`.

### Background jobs

Solid Queue runs inside Puma when `SOLID_QUEUE_IN_PUMA=true` (the Kamal default), or standalone with `bin/jobs`.

| Job | Trigger | Purpose |
| --- | --- | --- |
| `WebhookDeliveryJob` | domain events | signed delivery, 6 attempts with back-off |
| `TaskMailer.assigned` | assignment | tell the new assignee |
| `DueSoonRemindersJob` | daily 08:00 | email assignees of tasks due tomorrow |
| `PurgeDiscardedJob` | daily 03:00 | delete records soft-deleted > 30 days ago. Uses `ActiveJob::Continuable`, so a deploy mid-run resumes from its cursor |
| expired-session prune | daily 04:00 | `Session.expired.delete_all` |

Schedules live in [config/recurring.yml](config/recurring.yml).

## Testing & quality

```bash
bundle exec rspec                                   # the app, ~8 s; accepts any file or directory
bundle exec rspec spec gems deploy/lambda           # 1,036 (app + gems + Lambdas), what CI runs
for s in ai auth notifications; do (cd services/$s && bundle exec rspec); done   # the services
bin/rails ai:eval                                   # score the configured model against the golden sets
bin/ci                                              # rubocop + bundler-audit + brakeman + rspec with the coverage floor (as GitHub Actions)
RAILS_ENV=test bin/rails rswag:specs:swaggerize     # regenerate swagger/v1/swagger.yaml after API changes
```

- `spec/api` – [rswag](https://github.com/rswag/rswag) specs: each one exercises the endpoint **and** validates the response against the OpenAPI schema it publishes, so docs cannot drift.
- `spec/requests` – behaviour: authorization matrices, filters, pagination, rate limits, CORS, error envelope.
- `spec/models`, `policies`, `jobs`, `mailers`, `channels`, `services`, `subscribers` – unit level.
- [Bullet](https://github.com/flyerhzm/bullet) raises in the test environment on N+1 queries *and* unused eager loading.
- `spec/requests/api_docs_spec.rb` fails when a route is added without documenting it; `spec/requests/tenant_isolation_spec.rb` fails when one has no isolation decision.
- Load tests: `loadtest/` (k6) against a seeded 150k-task database; results in [docs/performance.md](docs/performance.md).
- More: [docs/testing.md](docs/testing.md), [CONTRIBUTING.md](CONTRIBUTING.md).

## Deployment

The app ships a production [Dockerfile](Dockerfile) and a [Kamal 2](https://kamal-deploy.org) config.

1. Edit [config/deploy.yml](config/deploy.yml): replace the `CHANGE_ME` values (server, domain, registry).
2. Export `KAMAL_REGISTRY_PASSWORD` and `TASK_API_DATABASE_PASSWORD`; `config/master.key` supplies `RAILS_MASTER_KEY`.
3. `bin/kamal setup` the first time, `bin/kamal deploy` after that.

Kamal boots a Postgres accessory (with the extra `cache`, `queue` and `cable` databases the Solid adapters use),
terminates TLS with kamal-proxy, and only shifts traffic once `GET /up` passes, so deploys are zero-downtime.
Uploads live on the `task_api_storage` volume.

**Credentials.** `config/credentials.yml.enc` is committed; `config/master.key` never is. Keep the key in your password manager and
in CI/Kamal secrets. Production needs the `active_record_encryption` keys it already contains (they encrypt webhook secrets).
Copy [.env.example](.env.example) for the full list of environment variables.

**Operations.**
- Logs are JSON on stdout (`LOG_FORMAT=plain` to disable); every line carries the request id. Domain events log as `event=task.completed subject=... project_id=...`.
- Set `SENTRY_DSN` to enable error tracking (no-op otherwise).
- **Backups are not automated.** Schedule `pg_dump` of all four production databases (and the storage volume) on the host, and rehearse a restore.
- Migrations run automatically (`db:prepare`) when a container starts; keep them backward compatible with the previous release so rolling deploys stay safe.

## Deploying to AWS (EKS)

Terraform builds AWS, Argo CD installs the cluster add-ons and the services from Git, GitHub Actions builds the images
and records the new tag. **Nothing has been applied to a real account**: the configuration validates (`terraform validate`, Helm
rendered for every environment and checked against Kubernetes and CRD schemas), and you provide the credentials and run it.
[docs/aws/setup-guide.md](docs/aws/setup-guide.md) lists every manual step in order (Bedrock access, SES, state bucket, secrets, database bootstrap, Argo CD,
DNS), with a verification checklist. Runbooks for the alerts are in [docs/runbooks/](docs/runbooks/).

A second region (an active/passive warm standby built from the same Terraform with `dr_role`, with a Route 53 failover pair) is written and checked offline with `terraform test`, but has never been applied: [docs/aws/multi-region.md](docs/aws/multi-region.md).

The Kamal path above still works for a single host, with `ACTIVE_STORAGE_SERVICE=local` and the monolith's own auth.

## Known limitations

- People join an organization by invitation, and the API never says whether an address is registered. Two narrow exceptions: an administrator is told when an address already belongs to a *member of their own organization*, and adding a user directly to a project that has **no** organization (`POST /projects/:id/memberships`) still answers 404 for an unknown address. Both are listed in [security.md](docs/security.md).
- `page=` is offset pagination: fine for this data shape, but a deep page of a huge project costs more (14 ms at row 49,000 of 50,000). The task list offers `cursor=` (keyset) for that; the other lists do not need it.
- Active Storage defaults to local disk; on Kubernetes set `ACTIVE_STORAGE_SERVICE=amazon` (S3).
- Image dimension analysis needs `libvips` at runtime (it is in the Docker image; locally `brew install vips`). Without it uploads still work, their dimensions are just not recorded. No image variants are generated.
- The inbox has no per-person settings (every notification kind is on) and no digest; see "Next" in [docs/roadmap.md](docs/roadmap.md). Teams grant project access but are flat (no team roles, no nested teams), and a person with an administrator's implicit access to a project, or access only through a team, is not in `GET /projects/:id/memberships`: that lists direct members; `GET /projects/:id/teams` lists the teams.
- GraphQL is read-only (writes are REST). A public demo is *supported* ([docs/demo.md](docs/demo.md): demo mode, a nightly reset, a Kamal destination) but not deployed; that is yours to run.
- The platform code is validated statically and by CI (the four images build, Terraform validates, every Helm release renders and passes
  Kubernetes/CRD schema checks) and the services were exercised together locally with an AWS mock. The Compose stack, the `kind` script and
  the Terraform have **not been run against Docker or AWS**. Expect a round of small fixes on first contact.
- Tasks and Projects stay in the monolith on purpose ([decision 21](docs/decisions.md)). Webhooks stay there too.
- Events for the other services go through a transactional outbox ([ADR 41](docs/decisions.md)): delivery is at-least-once and never lossy, but not ordered, and can be late during an SNS outage (alarm: oldest unpublished event over 5 minutes; [runbook](docs/runbooks/event-outbox.md)). Webhooks and Action Cable are separate and are not retried from the outbox.
- Access tokens from the Auth service live up to 15 minutes after logout.

## Documentation

| | |
| --- | --- |
| [docs/roadmap.md](docs/roadmap.md) | Everything that was planned and built, by pull request, with status and what is next |
| [docs/decisions.md](docs/decisions.md) | Why (34 architecture decisions) |
| [docs/architecture/](docs/architecture/overview.md) | System overview, AI, observability and AIOps, microservices, service contracts |
| [docs/testing.md](docs/testing.md) · [docs/performance.md](docs/performance.md) · [docs/security.md](docs/security.md) | How it is tested, measured and defended |
| [docs/api-versioning.md](docs/api-versioning.md) · [CHANGELOG.md](CHANGELOG.md) | Versioning policy and what changed for API clients |
| [docs/runbooks/](docs/runbooks/) | Operating it: alerts, backups and restores, zero-downtime migrations |
| [docs/aws/setup-guide.md](docs/aws/setup-guide.md) · [deploy/README.md](deploy/README.md) | Standing the platform up on AWS |
| [CONTRIBUTING.md](CONTRIBUTING.md) · [SECURITY.md](SECURITY.md) | Working on it; reporting a vulnerability |

## License

[MIT](LICENSE)
