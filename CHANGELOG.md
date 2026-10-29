# API changelog

Changes to what API clients can see and rely on, newest first. The format follows [Keep a Changelog](https://keepachangelog.com);
the API is versioned in the URL (`/api/v1`), and nothing here is breaking within a version
([what counts as breaking](docs/api-versioning.md)). Internal changes (refactors, infrastructure, tests) are in the pull requests
and in [docs/roadmap.md](docs/roadmap.md).

## Unreleased

### Added
- `GET /api/v1/projects/{id}/analytics`: counts by status and priority, tasks created and completed per day/week/month, cycle time
  (median and 90th percentile), and workload per assignee. Query: `from`, `to` (ISO 8601), `interval` (`day|week|month`).
- `GET /api/v1/activity`: what happened across all the caller's projects (projects, tasks, memberships), newest first.
  Filters: `project_id`, `type`.
- **Organizations.** `GET|POST /api/v1/organizations`, `GET|PATCH|DELETE /api/v1/organizations/{id}` and
  `GET|POST /api/v1/organizations/{id}/members`, `PATCH|DELETE /api/v1/organizations/{id}/members/{member_id}`.
  Roles `owner`, `admin`, `member`. Owners and admins administer every project of the organization.
- `organization_id` on projects. `POST /api/v1/projects` accepts it to create a project inside an organization you belong to; it
  cannot be changed later. A project in an organization only accepts members of that organization (`422` otherwise).
- `API-Version` header on every response. A version on its way out will also send `Deprecation`, `Sunset` and a
  `Link: ...; rel="successor-version"` header.
- `request_id` in every error body, equal to the `X-Request-Id` response header; quote it when reporting a problem.
- `API-Version`, `Deprecation` and `Sunset` are exposed to browsers through CORS.

### Changed
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
