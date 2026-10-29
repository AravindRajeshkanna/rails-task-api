# Extracting services (strangler fig)

The original application stays in front as the façade. Capabilities move behind it one at a time, each controlled by an
environment variable, so every step can be shipped, observed, and undone.

| # | Capability | Status | Switch | Data ownership after |
|---|---|---|---|---|
| 1 | **Auth** (users, credentials, JWT) | extracted | `AUTH_MODE=jwt` | credentials move to the Auth service; the monolith keeps a `users` row per identity |
| 2 | **AI** (inference, embeddings) | extracted | `AI_GATEWAY=remote` | stateless; retrieval and budgets stay in the monolith |
| 3 | **Notifications** (email, Slack) | extracted | `NOTIFICATIONS_MODE=remote` | the service owns delivery log and dedupe table |
| 4 | **Tasks and Projects** | stay | — | monolith (see "Why Tasks and Projects stay") |
| 5 | Webhooks | candidate | — | project-owned configuration; consuming the same event stream makes this mechanical |

## Rules that keep it from becoming a distributed monolith

1. **A service owns its data; nobody reads another service's tables.** The Auth service's `users` and the monolith's
   `users` projection are connected by a verified token, not by a shared database.
2. **Synchronous calls only where the user is waiting** (JWKS fetch, AI inference). Everything else is an event.
3. **Events carry what the consumer needs.** `task.assigned` includes the recipient, the task, the project and the link, so
   the Notification service never calls back.
4. **Consumers are idempotent.** SNS/SQS deliver at least once; the event id is the dedupe key.
5. **Contracts are documented and tested on both sides** ([service-contracts.md](service-contracts.md)); the monolith's
   `Gateway::Remote` is specified against the AI service's real error codes.
6. **Every extraction has a rollback that is a configuration change.**

## Cutover: Auth

The Auth service must issue tokens before the monolith stops accepting its own, and existing users must keep working.

1. Deploy the Auth service (`services/auth`) with an empty database. Leave the monolith on `AUTH_MODE=local`.
2. **Export** users from the monolith: `bin/rails auth:export_users OUT=users.jsonl` (mode 0600; it contains password
   hashes). **Import** in the Auth service: `bin/rails users:import IN=users.jsonl`. Hashes are bcrypt, so people keep
   their passwords; each user keeps their monolith id as `legacy_id`. Delete the file.
3. Point `AUTH_JWKS_URL` and `AUTH_ISSUER` at the Auth service. Route `/api/v1/{registrations,session,passwords}` to it
   (the ALB Ingress does; docker compose uses nginx).
4. Set `AUTH_MODE=jwt` on the monolith. A user's first request with a new token links their existing row through the
   `legacy_id` claim (never by email); new users are created from the token's claims. Clients keep sending
   `Authorization: Bearer <token>`; the login response still has `token` and `user`, plus `refresh_token`.
5. Watch: `bin/rails auth:status` (linked vs waiting), 401 rate, `account_conflict` (409) responses.

**Rollback:** `AUTH_MODE=local`. Users created only in the Auth service have no password in the monolith and cannot sign
in there (they get a clean 401), so roll back before significant new sign-ups, or export those users back.

**Known consequences.** Logout ends the refresh token immediately but an issued access token lives up to 15 minutes.
Profile edits (`PATCH /me`) answer 409 `managed_by_auth_service`; avatars remain in the monolith.

## Cutover: AI

1. Deploy `services/ai`; set the same `AI_SERVICE_TOKEN` on it and on the monolith and worker.
2. Set `AI_GATEWAY=remote` and `AI_SERVICE_URL=http://ai` on the monolith and worker. `AI_PROVIDER` is now only the AI
   service's business (`bedrock` there).
3. Compare `taskapi_ai_requests_total` and latency before and after. Budgets and the ledger are unchanged: the monolith
   still records every call from the usage the service returns.

**Rollback:** `AI_GATEWAY=local` (and a provider on the monolith).

## Cutover: Notifications

1. Deploy the Notification service and its queue (Terraform creates the topic, queue, DLQ and subscription).
2. Set `EVENTS_SNS_TOPIC_ARN` on the monolith so domain events reach SNS, and verify messages arrive (`ApproximateNumberOfMessagesVisible`,
   Notification service logs).
3. Set `NOTIFICATIONS_MODE=remote` on the monolith and worker: they stop sending assignment and reminder emails
   themselves.

**Doing 3 before 2 means nobody gets email.** Rollback: `NOTIFICATIONS_MODE=local`. During the switch an event can be
delivered twice or not at all for a moment; both are acceptable for reminders.

## Why Tasks and Projects stay

A task belongs to a project, and nearly every read checks membership (`TaskPolicy::Scope` joins memberships and kept
projects). Splitting them gives you either a network call in every list query or a replicated membership table kept
in sync by events, plus a distributed transaction for "create a task in a project I might have just been removed
from". The benefit would be independent deploys of two things that always change together. The seams to split later
already exist: policies are the only place that reads memberships, domain events are the only way other code learns
about changes, and nothing outside the monolith reads its tables.

## What a future Projects/Tasks split would need

An event-fed membership read model in the Task service; `project.*` events to carry membership changes; the audit log
and webhooks following their owners; and an id strategy (the Auth service's UUID subject is already in place for users).
