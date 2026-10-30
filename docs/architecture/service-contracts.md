# Service contracts

## Conventions

- JSON over HTTP. Errors are `{ "error": { "status": 422, "code": "...", "message": "...", "details": {...} } }` in the
  monolith and Auth service; the AI service uses `{ "error": { "code": "...", "message": "..." } }`.
- Service-to-service HTTP carries a bearer token (`AI_SERVICE_TOKEN`) or a JWT; trace context is added automatically by
  the OpenTelemetry Net::HTTP instrumentation (`traceparent` and `X-Amzn-Trace-Id`).
- Events are CloudEvents 1.0, structured JSON.

## Auth service

Public (the ALB routes these paths to it; the paths and shapes match what the monolith used to serve):

| Method and path | Body | Success | Errors |
|---|---|---|---|
| `POST /api/v1/registrations` | `name`, `email_address`, `password` (≥ 8) | 201 session | 422 `validation_failed`, 429 |
| `POST /api/v1/session` | `email_address`, `password` | 201 session | 401 `invalid_credentials`, 429 |
| `POST /api/v1/session/refresh` | `refresh_token` | 200 session (new pair) | 401 `invalid_refresh_token`, `refresh_token_reused` |
| `DELETE /api/v1/session` | `refresh_token` | 204 (always) | — |
| `POST /api/v1/passwords` | `email_address` | 202 (always) | 429 |
| `PATCH /api/v1/passwords/:token` | `password`, `password_confirmation` | 204 | 422 `invalid_token` / `validation_failed` |

Session: `{ "data": { "token": "<JWT>", "expires_at": "...", "refresh_token": "...", "refresh_expires_at": "...", "user": { "id": "<uuid>", "name", "email_address", "created_at" } } }`.
The `token` is the bearer token for every API call. `user.id` is the identity id; the Task API's `GET /me` returns the application's own user id.

Internal: `GET /.well-known/jwks.json`, cacheable for 5 minutes.

**Access token (RS256, 15 minutes).** Header `kid` = RFC 7638 thumbprint. Claims:

| Claim | Meaning |
|---|---|
| `iss` | `AUTH_ISSUER` |
| `aud` | `task-api` |
| `sub` | the user's UUID in the Auth service |
| `exp`, `iat`, `nbf`, `jti` | standard; `exp` and `sub` are mandatory (verifiers reject tokens without them) |
| `email`, `name` | profile, synced to the monolith's `users` row on each request |
| `legacy_id` | present only for accounts imported from the monolith; used once to link them |

Verifiers accept RS256 only (no `none`, no HMAC), check issuer and audience, allow 30 s of clock skew, refetch the key set
once on an unknown `kid` (at most every 30 s), and answer 503 rather than 401 when the key set cannot be fetched.

## AI service

All require `Authorization: Bearer <AI_SERVICE_TOKEN>`; bodies are capped at 512 KB.

| Endpoint | Request | Response |
|---|---|---|
| `POST /v1/features/:name` | `{ "input": { ... } }` | `{ "output": { ... }, "usage": { input_tokens, output_tokens, model_id, latency_ms } }` |
| `POST /v1/converse` | `{ system, messages: [...], tools: [...] }` (Bedrock Converse message shape) | `{ message, stop_reason, usage }` |
| `POST /v1/embeddings` | `{ "text": "..." }` | `{ "vector": [1024 floats], "usage": {...} }` |

Features and their `input` shapes are defined by the classes in `gems/ai_core/lib/ai_core/features/` (`parse_task`,
`suggest_priority`, `suggest_tags`, `summarize_project`, `analyze_incident`), each with a JSON schema.

Error codes: `unauthorized` 401 · `invalid_request` 400/422/413 · `unknown_feature` 404 · `rate_limited` 429 ·
`ai_invalid_response` 502 · `ai_error` 502 · `ai_unavailable` 503 (with `Retry-After: 5`) · `ai_not_configured` 503.
The monolith's `Ai::Gateway::Remote` maps these to its own errors and from there to its API errors.

## Events

Envelope (published by the monolith to the SNS topic, `source: "task-api"`):

```json
{
  "specversion": "1.0",
  "id": "5f1c…",                      // unique per event; consumers deduplicate on it
  "source": "task-api",
  "type": "task.assigned",
  "time": "2026-10-29T12:00:00.000Z",
  "datacontenttype": "application/json",
  "subject": "gid://task-api/Task/7",
  "projectid": 3,
  "data": { … }
}
```

SNS message attributes (for subscription filters): `type`, `source`, `project_id` (number).

**Delivery guarantees.** Events are written to a transactional outbox in the transaction of the change they describe and published afterwards, so:
an event exists if and only if its change committed; it is delivered **at least once** (a crash can resend it: deduplicate on `id`); delivery is **not ordered**
(use `time` and the current state, not arrival order); and during an SNS outage events are late, never lost. `data` is a snapshot taken at the moment of the
change, not re-read at publish time. The daily `task.due_soon` has a deterministic `id` per task and due date, so a re-run of the job repeats the same event.
See [the outbox runbook](../runbooks/event-outbox.md).

| Type | When | `data` |
|---|---|---|
| `task.created`, `task.updated`, `task.completed`, `task.discarded`, `task.restored` | the task changes | the task, as the API serializes it |
| `project.created`, `project.updated`, `project.discarded`, `project.restored` | likewise | the project |
| `comment.created`, `comment.updated` | likewise | the comment |
| **`task.assigned`** | someone other than the assignee assigns the task | `task`, `project {id,name}`, `recipient {id,name,email_address,email_enabled}`, `actor {id,name}`, `url` |
| **`task.due_soon`** | daily 08:00, for open tasks due tomorrow | `task`, `project`, `recipient`, `actor` (nil), `url` |

`recipient.email_enabled` is `false` when the person muted this kind or project, or takes a daily digest instead of an email per event (decided by the monolith from their settings when it builds the event). A consumer that sends email must not send it for `false`; absent means `true`, as before the field existed.
| `user.password_reset_requested` *(source `auth-service`)* | a reset is requested for a real account | `recipient {id,name,email_address}`, `reset_url`, `expires_in_minutes` |

Guarantees: at least once, possibly out of order, one event per committed change. Events for records deleted before
publishing are dropped. A change that commits while SNS is unreachable is retried by the job for up to 10 attempts; beyond
that it is a failed job (alarm `FailedJobs`). Adding a field is compatible; renaming or removing one is a new type.

Queues (Terraform): `task-api-<env>-notifications` (visibility 60 s, 5 receives then `…-notifications-dlq`, retained 14
days), subscribed with raw delivery and a filter on `type`.

## Metrics (Prometheus, `GET /metrics`, private)

| Metric | Labels | Source |
|---|---|---|
| `taskapi_http_requests_total`, `taskapi_http_request_duration_seconds` | controller, action, status | monolith |
| `taskapi_domain_events_total` | event | monolith |
| `taskapi_ai_requests_total`, `taskapi_ai_tokens_total`, `taskapi_ai_cost_usd_total`, `taskapi_ai_request_duration_seconds`, `taskapi_ai_budget_rejections_total` | feature, outcome/direction | monolith |
| `taskapi_queue_ready_jobs{queue}`, `…_oldest_ready_job_age_seconds{queue}`, `…_claimed_jobs`, `…_scheduled_jobs`, `…_failed_jobs`, `…_workers` | — | read from the database at scrape time (reported by every web pod: aggregate with `max`) |
| `taskapi_db_pool_connections{state}` | size, busy, idle, waiting | monolith |
| `service_http_*`, `ai_service_*`, `notifications_*` | | the services |

CloudWatch EMF series (namespace `TaskApi`, dimension `Environment`): `QueueDepth`, `OldestJobAgeSeconds`, `FailedJobs`, `Workers`.
