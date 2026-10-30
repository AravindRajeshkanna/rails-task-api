# API changelog

Changes to what API clients can see and rely on, newest first. The format follows [Keep a Changelog](https://keepachangelog.com);
the API is versioned in the URL (`/api/v1`), and nothing here is breaking within a version
([what counts as breaking](docs/api-versioning.md)). Internal changes (refactors, infrastructure, tests) are in the pull requests
and in [docs/roadmap.md](docs/roadmap.md).

## Unreleased

### Changed
- **New limits and a new refusal.** `429 rate_limited` can now also mean: the endpoint's own budget (search, analytics, the activity feed, audit logs and GraphQL: 120 per 5 minutes per token) or the organization's budget
  (3,000 writes per 5 minutes across all its clients; `Retry-After` is the end of the window). Under load the expensive reads (the same endpoints, and `/ai/*`) answer `503 overloaded` with a `Retry-After` of one or two
  seconds while cheap reads and all writes keep being served.
- `503 ai_unavailable` now carries a `Retry-After` that reflects the circuit breaker: 5 seconds for a single failure, and the rest of the pause (30 seconds, doubling to 5 minutes) once the AI dependency has been failing. After five consecutive failures AI calls fail at once instead of waiting out their timeout.

### Added
- **Token rotation and sign-in management.** `POST /session/rotate` exchanges the token you are using for a new one (the old one stops working at once; 30 a hour). `GET /sessions` lists your
  sign-ins (address, client, created, last used, `current`) and `DELETE /sessions/:id` ends one (someone else's is `404`). Not available when the Auth service issues tokens (`404`), and refused in the public demo.
  A token that has not been used for 14 days now expires, ahead of its 30-day lifetime; a client that goes quiet for two weeks has to sign in again.
- **Sparse fieldsets.** `fields=` on `GET /projects/{id}/tasks`, `GET /tasks/{id}` and `GET /projects`: a comma-separated list of the attributes and associations wanted (`id` is always included). Unrequested
  associations are not loaded. An unknown name is `400` with the valid names. Without `fields`, responses are unchanged.
- **Idempotency keys.** The `Idempotency-Key` request header on every create endpoint (projects, tasks, comments, memberships, tags, webhooks, organizations and their invitations, teams
  and their members and project grants, notification mutes, and `POST /ai/create_from_text`): a retry with the same key returns the first response (`Idempotent-Replayed: true`) and does
  nothing twice. New errors: `422 idempotency_key_reused`, `409 idempotency_in_progress` (with `Retry-After`). Optional; behavior without the header is unchanged.
- CORS now exposes `X-Demo-Mode` to browsers (a front end can show a "this is a demo" banner), alongside the headers it already exposed.
- **Nested teams.** `parent_id` on `POST|PATCH /api/v1/organizations/{id}/teams` (null to move a team out) and on team responses. A team can have a parent in the same organization; teams nest one
  level. The members of a sub-team have the project access its parent was granted, on top of its own; a grant to a sub-team reaches only that sub-team. A team with sub-teams cannot be deleted
  (`422`) or become a sub-team. Moving a team changes who has access to what.
- **Team maintainers.** Team members have a `role`, `member` (default) or `maintainer`: `POST .../teams/{id}/members` accepts `role` (only owners and admins can add a maintainer),
  and `PATCH .../teams/{id}/members/{member_id}` with `{ "role": ... }` changes it (owners and admins). A maintainer can add and remove the plain members of their own team; the
  role grants no access to any project. Team member responses carry `role`.
- **GraphQL mutations:** `createTask`, `updateTask`, `deleteTask`, `createComment`, `markNotificationRead`. Each is the REST write reached another way (same policies, same
  validation, optimistic locking, audit log and events). Mistakes in the input come back in the payload's `errors`; a missing or invisible record, a forbidden action and a stale
  `lockVersion` are top-level errors with `extensions.code` `not_found`, `forbidden` and `stale_object`. One mutation per request. No subscriptions. Additive: queries are unchanged.
- `cursor` on `GET /api/v1/projects/{id}/audit_events`, `GET /api/v1/organizations/{id}/audit_events` and `GET /api/v1/activity`: keyset pagination as on the task list
  (`?cursor=` first page, then `meta.next_cursor`; `meta` is `{limit, next_cursor, has_more}` with no total; an invalid cursor is `400`). The same cost at any depth of history.
  `page=` is unchanged.
- **Notification settings.** `GET|PATCH /api/v1/notification_settings` (`digest`: `off` or `daily`; `digest_hour` 0-23; `time_zone`, an IANA name) and
  `GET|POST /api/v1/notification_mutes`, `DELETE /api/v1/notification_mutes/{id}` (give `kind`, `project_id`, or both). A muted notification is not stored in the inbox,
  emailed, or put in the digest. With a daily digest there is no email per assignment or reminder: one summary of what is new and unread arrives at the chosen hour in the
  chosen time zone. Updating the digest is refused (`403 demo_mode`) in the public demo.
- Events for other services: `task.assigned` and `task.due_soon` carry `data.recipient.email_enabled`, false when the person muted it or takes a digest. The Notification
  service sends no email for `false`; a consumer that ignores the field behaves as before (adding a field is compatible).
- `503 read_only` (with `Retry-After`) for any write while the service is read-only: during a database promotion or planned maintenance. Reads, including
  GraphQL queries and requests with an existing token, keep working. Nothing was changed by the refused request, so retry it as it is. Signing in is a write
  and waits too.
- `GET /api/v1/projects/{id}/analytics`: counts by status and priority, tasks created and completed per day/week/month, cycle time
  (median and 90th percentile), and workload per assignee. Query: `from`, `to` (ISO 8601), `interval` (`day|week|month`).
- `GET /api/v1/activity`: what happened across all the caller's projects (projects, tasks, memberships), newest first.
  Filters: `project_id`, `type`.
- **Organizations.** `GET|POST /api/v1/organizations`, `GET|PATCH|DELETE /api/v1/organizations/{id}` and
  `GET /api/v1/organizations/{id}/members`, `PATCH|DELETE /api/v1/organizations/{id}/members/{member_id}`.
  Roles `owner`, `admin`, `member`. Owners and admins administer every project of the organization.
- `cursor` on `GET /api/v1/projects/{id}/tasks`: keyset pagination (`?cursor=` first page, then `meta.next_cursor`; `meta` is `{limit, next_cursor, has_more}` with no
  total). Same cost at any depth, stable while tasks are added or removed. For sorts by `created_at`, `updated_at` or `title`; relevance, `priority`, `status` and
  `due_on` stay with `page=`. An invalid cursor is `400`. `page=` is unchanged.
- Events for other services (the SNS topic) are now written to a transactional outbox in the same transaction as the change and published by a relay: they can
  no longer be lost to a crash after commit or to an SNS outage, and are still delivered at least once (deduplicate on `id`). `data` is a snapshot at the time of
  the change. Not an API change, but consumers of the topic should note delivery can be late and out of order during an outage. (Listed here because it is
  a guarantee these consumers can now rely on.)
- **GraphQL (read-only).** `POST /api/v1/graphql` with `{ query, variables, operationName }`: `me`, `projects`, `project`, `task`, `search`, `notifications`, with
  connections, the REST task filters, and the same access rules as REST (a record you cannot see is `null`). At most 20 KB, 8 levels deep, 1,500 complexity points,
  100 per page, one operation per request. The schema is `docs/graphql/schema.graphql`. Writes remain REST.
- Responses from a public-demo instance carry `X-Demo-Mode: true`, and the demo refuses (`403 demo_mode`) sign-up, uploads, webhooks, invitations and AI.
- **In-app inbox.** `GET /api/v1/notifications` (newest first; `unread=true`, `project_id`, `kind`; `meta.unread_count`), `PATCH /api/v1/notifications/{id}`
  with `{"read": true|false}`, `DELETE /api/v1/notifications/{id}` and `POST /api/v1/notifications/read_all` (optionally `project_id`). You are told when a
  task is assigned to you by someone else (`task.assigned`), when one of yours is due tomorrow (`task.due_soon`), when someone else completes a task you created
  (`task.completed`) and when someone else comments on a task you created or are assigned (`comment.created`). New ones are pushed over Action Cable
  (`NotificationsChannel`, `{event: "notification.created", data: ...}`). Notifications in a project you have left or that is archived are not listed;
  read ones are removed after 30 days, unread after 180.
- **Full-text search.** `GET /api/v1/search?q=` searches task titles and descriptions across every project you can see, best match first
  (title matches outrank description matches), with the task's project, a rank, and highlights (matched words wrapped in `«»`, plain text).
  `GET /api/v1/projects/{id}/tasks?search=` does the same inside one project (best match first unless `sort` is given). Words are stemmed
  (`deploying` finds `deployed`), `"quoted phrases"`, `or` and `-excluded` work, any text is safe, at most 200 characters. `q` still means substring.
- **Teams.** Groups inside an organization that a project can grant access to as a unit. `GET|POST /api/v1/organizations/{id}/teams`,
  `GET|PATCH|DELETE /api/v1/organizations/{id}/teams/{team_id}`, `GET|POST /api/v1/organizations/{id}/teams/{team_id}/members` (by `user_id`; the person
  must be in the organization) and `DELETE .../members/{member_id}`: owners and admins manage them, any member of the organization can read them.
  `GET|POST /api/v1/projects/{id}/teams` and `PATCH|DELETE /api/v1/projects/{id}/teams/{grant_id}` give a team of the project's organization access
  as `member` or `admin`. A person's role in a project is the highest of their own membership, their teams' grants and (as admin) administering the
  organization. Team members can be assigned tasks. Leaving the organization removes someone from its teams; deleting a team ends the access it gave.
- `GET /api/v1/organizations/{id}/audit_events` (owners; filter `auditable_type`): the organization's history, newest first: renames, invitations
  sent, accepted and withdrawn, members joining, changing role and leaving, each with who did it and what changed.
- **Invitations.** People join an organization by invitation, not by being added:
  `POST /api/v1/organizations/{id}/invitations` (email address, role; mails a link, valid 7 days; sending again refreshes it),
  `GET` the open ones, `DELETE /api/v1/organizations/{id}/invitations/{id}` to withdraw one, and
  `POST /api/v1/invitations/accept` with the emailed `token`, signed in as the invited address. The answers are the same whether or
  not the address belongs to a registered user, and the token is only in the email. (There is no `POST .../members`: it would have told
  administrators which addresses are registered. It was never in a tagged release.)
- `organization_id` on projects. `POST /api/v1/projects` accepts it to create a project inside an organization you belong to; it
  cannot be changed later. A project in an organization only accepts members of that organization (`422` otherwise).
- `API-Version` header on every response. A version on its way out will also send `Deprecation`, `Sunset` and a
  `Link: ...; rel="successor-version"` header.
- `request_id` in every error body, equal to the `X-Request-Id` response header; quote it when reporting a problem.
- `API-Version`, `Deprecation` and `Sunset` are exposed to browsers through CORS.

### Changed
- `GET /api/v1/activity` also covers `ProjectTeam` (a team being given or losing access to a project; filter `type=ProjectTeam`).
- Fixed: a person who administers a project's organization *and* is a plain member of the project is an admin everywhere. Lists already said so; the
  per-record check that single resources use took the direct role first and treated them as a member.
- Removing someone from a project is now recorded in its audit log and activity feed (`action: "destroy"`, the member's attributes going to `null`);
  previously only additions and role changes were. Audit event `action` can now also be `destroy`, `accept` and `revoke`.
- Adding someone to a project **of an organization** by email now answers `422` ("must be a member of the project's organization") for an
  unknown address, the same as for a registered user outside the organization; it used to be `404` for an unknown address. Adding people
  is throttled (60 an hour per user). Projects without an organization are unchanged.
- Responses now say how they may be cached: `Cache-Control: no-cache, private` and `Vary: Authorization, Accept` (clients may keep a
  copy and revalidate with `If-None-Match`; `304` is answered), and `Cache-Control: private, no-store` on sign-in and sign-up.
- Every response carries security headers (`Content-Security-Policy: default-src 'none'`, `X-Frame-Options: DENY`,
  `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`). They only matter if a browser is ever pointed straight at the API.
- A failed delete (an organization that still has projects, a member who still owns projects) answers `422` with the reason in `details`.
- Documentation: the OpenAPI document gains the `Organizations`, `Analytics` and `Activity` tags and describes versioning.

### Security
- Check constraints in the database refuse unknown statuses, priorities and roles, blank names and negative counters, even from code
  that skips model validations. The API already rejected all of these with `422`; nothing changes for well-behaved clients.

### Fixed
- Uploaded images are analysed again (width and height recorded): a dependency update had dropped the library that does it.

## 2026-10-29: AI, services and platform ([#5](https://github.com/AravindRajeshkanna/rails-task-api/pull/5))

### Added
- `POST /api/v1/ai/{suggest_priority,suggest_tags,suggest_assignee,create_from_text,chat}`, `GET /api/v1/ai/usage` and
  `GET /api/v1/projects/{id}/summary`: AI helpers with per-user token budgets (`429 ai_budget_exceeded`) and rate limits;
  `503 ai_not_configured` when the server has no model provider. Errors `ai_error`, `ai_invalid_response`, `ai_unavailable`.
- Optional external authentication: with `AUTH_MODE=jwt`, bearer tokens are RS256 JWTs issued by the Auth service
  (`/api/v1/{registrations,session,passwords}` are then served by it); `401 unauthenticated` is unchanged.
- Errors `account_conflict` (`409`) and `auth_unavailable` (`503`).
- `/metrics` (Prometheus), reachable from inside the cluster only.

## 2026-10-29: first release of `/api/v1` ([#1](https://github.com/AravindRajeshkanna/rails-task-api/pull/1))

### Added
- Registration, sign-in/out and password reset with bearer tokens; the current user (`/me`) and avatar.
- Projects (soft delete and restore), memberships with roles `member` and `admin`, tasks (soft delete and restore, optimistic locking via
  `lock_version`, filtering, sorting, text search), comments, tags, attachments, webhooks with delivery history, and a per-project audit log.
- Pagination (`page`, `limit`; `Link`, `Total-Count`, `Total-Pages`, `Current-Page`, `Page-Limit` headers), the `{data, meta}` envelope and
  the `{error: {status, code, message, details}}` envelope, rate limiting (`429 rate_limited`, `Retry-After`), CORS, and real-time
  updates over Action Cable.
