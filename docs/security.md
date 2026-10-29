# Security

What protects the API, where each control lives, and how it is tested. Report a vulnerability privately to the repository owner; do not open a public issue.

## The model in one paragraph

Every request is authenticated by a bearer token (or a short-lived JWT when the Auth service is on), authorized per record by a
Pundit policy, and scoped to the projects the caller belongs to before any record is looked up. Anything outside that scope is a
**404, not a 403**, so existence is not disclosed. The API renders JSON for programs, never HTML, so a browser is never asked to
trust it, and the response headers say so.

## Controls

| Concern | Control | Where | Tested in |
| --- | --- | --- | --- |
| Authentication | Random 190-bit tokens, only SHA-256 digests stored; passwords with bcrypt; password reset signs out every device; Auth service: RS256 JWTs (15 min), rotating single-use refresh tokens with reuse detection | `Session`, `Authentication`, `services/auth` | `authentication_spec`, `authentication_journey_spec`, `services/auth/spec` |
| Authorization | Pundit, default deny; `verify_authorized` and `verify_policy_scoped` make a forgotten check raise | `app/policies`, `Api::V1::BaseController` | `spec/policies`, `tenant_isolation_spec` |
| IDOR / tenant isolation | Child resources are found through `policy_scope`; outsiders get 404; organization boundary on project membership | `ApplicationPolicy::Scope`, `Membership` | `tenant_isolation_spec`, `project_policy_organization_spec` |
| Mass assignment | Strong parameters on every action; role, owner and organization are never permitted attributes of an update | controllers | `authentication_spec` ("does not let clients mass-assign other attributes"), `organizations_spec` |
| Input validation | Model validations **and** CHECK constraints; query parameters through allow-lists (`TaskQuery`, `Analytics::ReportForm`), never interpolated into SQL | models, `db/migrate`, `app/queries`, `app/forms` | `constraints_spec`, `report_form_spec` |
| Injection | Active Record everywhere; the few SQL fragments take only allow-listed or sanitized values; prompt-injection hygiene for AI input | | Brakeman in CI |
| Output | JSON only. Stored text is returned as typed, so **clients must escape it** when rendering HTML | | |
| Security headers | `secure_headers`: CSP `default-src 'none'`, `X-Frame-Options: DENY`, `nosniff`, `Referrer-Policy: no-referrer`; HSTS from `force_ssl`; Swagger UI alone gets a policy it can run under | `config/initializers/secure_headers.rb` | `security_headers_spec` |
| Caching | Responses are `no-cache, private` with `Vary: Authorization`; anything carrying a credential is `no-store` | `ApplicationController` | `http_caching_spec` |
| CORS | Allow-list from `CORS_ORIGINS`; nothing allowed by default in production | `config/initializers/cors.rb` | `cors_spec` |
| Rate limiting | Per token, per IP, per login email (Rack::Attack) plus Rails 8 `rate_limit` on sign-in, sign-up and reset; AI has per-user request and token budgets. `RACK_ATTACK_ENABLED=false` is an emergency off-switch | `config/initializers/rack_attack.rb` | `rate_limiting_spec` |
| SSRF | Webhook URLs are resolved and refused if they point at private, loopback or metadata addresses, re-checked at delivery | `app/services/webhooks` | `url_guard_spec`, `deliverer_spec` |
| Secrets | Rails credentials plus environment variables locally; AWS Secrets Manager through External Secrets in the cluster; nothing in git (`.env`, `master.key` ignored) | `.env.example`, `deploy/` | |
| Supply chain | `bundler-audit` and Brakeman (the app and each service) on every PR; Dependabot for gems and Actions; images use immutable tags | `.github/workflows/ci.yml` | CI |
| Data integrity | Soft delete with restore, append-only audit log, optimistic locking | | |

## OWASP API Security Top 10 (2023)

| Risk | Status |
| --- | --- |
| API1 Broken object-level authorization | Mitigated: policy scopes plus the isolation sweep that fails on any route not in its table |
| API2 Broken authentication | Mitigated: digest-only tokens, throttled sign-in, reset revokes sessions, JWT verification requires `exp`/`sub` and RS256 only |
| API3 Broken object property-level authorization | Mitigated: explicit Alba resources (nothing from `as_json`); `UserSummaryResource` omits email; webhook secrets shown once |
| API4 Unrestricted resource consumption | Mitigated: throttles, page size capped at 100, analytics range capped at 120 buckets, upload type and size limits, AI budgets |
| API5 Broken function-level authorization | Mitigated: admin-only actions in policies, tested per role |
| API6 Unrestricted access to sensitive business flows | Partly: sign-up, reset, AI, invitations and invitation redemption are rate limited; no CAPTCHA |
| API7 SSRF | Mitigated for webhooks (above) |
| API8 Security misconfiguration | Mitigated: secure headers, CORS allow-list, Host authorization (when `ALLOWED_HOSTS` is set), fail-closed on missing secrets, `consider_all_requests_local` off |
| API9 Improper inventory management | Mitigated: one versioned OpenAPI document kept in sync by CI; deprecation headers for retiring a version |
| API10 Unsafe consumption of APIs | Mitigated: the model's output is validated like untrusted input; remote services are called with timeouts and verified tokens |

## Known gaps

- **Who is registered.** Joining an organization is by invitation, which answers identically for registered and unregistered addresses, and
  adding someone to a project *of an organization* answers identically for an unknown address and a registered stranger. What is still visible:
  inviting an address that already belongs to a member of the same organization is a `422` (the administrator can list those members anyway);
  and `POST /projects/:id/memberships` on a project **without** an organization still says `404` for an unknown address. Both are throttled
  (60 adds an hour per user) rather than closed; a personal project is the legacy path, and inviting people to it is not built.
- Invitation tokens are bearer secrets in an email: whoever reads the mailbox and can sign in as that address can join. The address must match the
  signed-in user, so a forwarded link does nothing for anyone else, but the API does not verify email ownership at sign-up (the Auth service does,
  in JWT mode, through its `email` claim).
- No audit log for organization membership changes yet (project and task changes are audited).
- Access tokens from the Auth service remain valid up to 15 minutes after sign-out.
- No automated secret scanning in CI (e.g. gitleaks); add it before the repository takes outside contributions.
