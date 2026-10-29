# Task API

A task and project management **JSON API** built on **Rails 8.1** (API-only), Ruby 4.0 and PostgreSQL.
Users sign up, create projects, invite teammates, and manage tasks with comments, tags, file attachments,
real-time updates and signed webhooks.

It is also a worked example of "modern Rails": the Solid stack instead of Redis, the built-in authentication
and rate-limiting primitives, structured events, Active Job continuations, and Kamal 2 deploys.
The reasoning behind each non-obvious choice is in [docs/decisions.md](docs/decisions.md).

- **Interactive docs:** run the server and open <http://localhost:3000/api-docs> (OpenAPI 3, generated from the specs)
- **Spec:** [swagger/v1/swagger.yaml](swagger/v1/swagger.yaml)

## What's in it

| Area | Implementation |
| --- | --- |
| Resources | Users, Projects, Memberships, Tasks, Comments, Tags, Webhooks, Audit events |
| Auth | Bearer-token sessions (digest-only storage), sign-up, sign-in/out, password reset |
| Authorization | Pundit policies; project roles `member` / `admin`; owner-only deletes |
| API design | `/api/v1` namespace, shallow routes, [Alba](https://github.com/okuramasafumi/alba) serializers, [Pagy](https://github.com/ddnexus/pagy) pagination, filtering / sorting / search, one error envelope |
| Hardening | `rack-cors`, `rack-attack` + Rails 8 `rate_limit`, optimistic locking, SSRF-guarded webhooks |
| Background work | Solid Queue: assignment & reminder emails, webhook delivery with retries, retention purge |
| Real time | Solid Cable: `ProjectChannel` pushes task and comment events |
| Storage | Active Storage: user avatars, task attachments (type and size validated, signed short-lived URLs) |
| Caching | Solid Cache: per-project task statistics, invalidated by `touch` |
| Rails 8.1 | `Rails.event` structured events, `ActiveJob::Continuable`, `bin/ci` local CI |
| Data safety | Soft delete + restore, 30-day purge, append-only audit log |
| Quality | RSpec (352 examples), Bullet raising on N+1, RuboCop, Brakeman, bundler-audit |
| Delivery | Dockerfile, Kamal 2 config, GitHub Actions, JSON logs, `/up` health check, optional Sentry |

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

**Rate limits** (`429` + `Retry-After`): sign-up 10/hour per IP; sign-in and password reset 10 per 3 minutes per IP, and
5 sign-ins per minute per account; everything under `/api` 300 per 5 minutes per IP and 600 per 5 minutes per token.

**Pagination.** `?page=2&limit=50` (default 25, max 100). The body has `meta` (`page`, `limit`, `count`,
`pages`, `next`, `previous`) and responses carry `Link` (RFC 8288), `Total-Count`, `Total-Pages`,
`Current-Page` and `Page-Limit` headers.

**Task filters** (`GET /api/v1/projects/:id/tasks`, all combinable):
`status`, `priority` (comma lists), `assignee` (`me` / `unassigned` / id), `tag`, `due_from`, `due_to`,
`overdue=true`, `q` (title + description search), `sort` (`-priority,due_on`; prefix `-` for descending).

**Optimistic locking.** Tasks expose `lock_version`; send it back on `PATCH` and a concurrent edit returns `409`.

**Soft delete.** `DELETE` on projects and tasks hides them; `POST .../restore` brings them back. They are
purged for good after 30 days.

### Endpoints

| | |
| --- | --- |
| Auth | `POST /registrations` · `POST /session` · `DELETE /session` · `POST /passwords` · `PATCH /passwords/:token` |
| Account | `GET` `PATCH /me` · `PUT` `DELETE /me/avatar` |
| Projects | `GET` `POST /projects` · `GET` `PATCH` `DELETE /projects/:id` · `POST /projects/:id/restore` |
| Members | `GET` `POST /projects/:id/memberships` · `PATCH` `DELETE /memberships/:id` |
| Tasks | `GET` `POST /projects/:id/tasks` · `GET` `PATCH` `DELETE /tasks/:id` · `POST /tasks/:id/restore` |
| Comments | `GET` `POST /tasks/:id/comments` · `PATCH` `DELETE /comments/:id` |
| Attachments | `POST /tasks/:id/attachments` (multipart `files[]`) · `DELETE /attachments/:id` |
| Tags | `GET` `POST /projects/:id/tags` · `DELETE /tags/:id` |
| Webhooks | `GET` `POST /projects/:id/webhooks` · `GET` `PATCH` `DELETE /webhooks/:id` · `GET /webhooks/:id/deliveries` |
| Audit | `GET /projects/:id/audit_events` (admins) |

All paths are under `/api/v1`. Full parameter and schema detail: `/api-docs`.

### Roles

| | member | admin | owner |
| --- | :-: | :-: | :-: |
| View project, create & edit tasks, comment, tag | ✓ | ✓ | ✓ |
| Delete own tasks / comments | ✓ | ✓ | ✓ |
| Delete any task or comment, restore tasks | | ✓ | ✓ |
| Edit project, manage members, webhooks, audit log | | ✓ | ✓ |
| Delete / restore the project | | | ✓ |

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

```
app/
  controllers/api/v1/   thin controllers: authorize → query → serialize
  controllers/concerns/ Authentication (bearer), ErrorHandling (envelope), Pagination (Pagy)
  policies/             Pundit: who may do what, and the scopes that hide other tenants' rows
  resources/            Alba serializers (response shape lives here, not in models)
  queries/              TaskQuery: allow-listed filters and sorting
  models/               validations, scopes; concerns: Discardable, Auditable, EventEmitting
  subscribers/events/   react to domain events: log, broadcast (Cable), webhooks
  services/             EventPayload, Webhooks::Deliverer, Webhooks::UrlGuard
  jobs/ mailers/ channels/
```

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
bundle exec rspec                                   # 352 examples, ~5 s
bin/ci                                              # rubocop + bundler-audit + brakeman + rspec (same as GitHub Actions)
RAILS_ENV=test bin/rails rswag:specs:swaggerize     # regenerate swagger/v1/swagger.yaml after API changes
```

- `spec/api` – [rswag](https://github.com/rswag/rswag) specs: each one exercises the endpoint **and** validates the response against the OpenAPI schema it publishes, so docs cannot drift.
- `spec/requests` – behaviour: authorization matrices, filters, pagination, rate limits, CORS, error envelope.
- `spec/models`, `policies`, `jobs`, `mailers`, `channels`, `services`, `subscribers` – unit level.
- [Bullet](https://github.com/flyerhzm/bullet) raises in the test environment on N+1 queries *and* unused eager loading.
- `spec/requests/api_docs_spec.rb` fails when a route is added without documenting it.

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

## Known limitations

- Members are added by the email of an **existing** user; there is no invitation flow, and an admin can therefore probe whether an email is registered.
- Offset pagination: fine for this data shape, but very deep pages on huge projects would want keyset pagination.
- Active Storage uses local disk. Switch `config.active_storage.service` to S3/GCS for multi-server setups.
- Image dimension analysis uses `libvips` when present (it is in the Docker image). Locally you will see a harmless boot warning unless you `brew install vips`; no image variants are generated.
- No GraphQL endpoint (optional in the roadmap); no public demo deployment is bundled.

## License

[MIT](LICENSE)
