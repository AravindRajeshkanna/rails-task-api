# Threat model

Who could attack this system, through which door, what they would gain, what stops them and what does not. [security.md](security.md) lists the controls; this page starts from the attacker and checks each control against a way around it. Method: list the assets, the actors and the trust boundaries, then walk STRIDE (spoofing, tampering, repudiation, information disclosure, denial of service, elevation of privilege) over each boundary. Review it when a boundary changes (a new service, a new way to authenticate, a new place data is sent) and after any incident.

**Out of scope:** the cloud provider's own security, physical access, and a malicious maintainer of the repository.

## Assets, most valuable first

1. **Tenant isolation.** Another organization's tasks, comments and files. One leak across tenants ends the product's promise.
2. **Credentials and keys.** Password hashes, session tokens (stored as digests), the Auth service's signing key, database passwords, the Rails credentials key (which decrypts the webhook-secret encryption keys), service tokens.
3. **Personal data.** Names, addresses, sign-in addresses ([data-protection.md](data-protection.md)).
4. **Availability.** The API answering within its objectives ([slo.md](slo.md)).
5. **Money.** AI calls cost per token; compute costs per pod.
6. **Integrity of history.** The audit trail and the event stream other systems act on.

## Actors

| Actor | Starts with | Wants |
| --- | --- | --- |
| Anonymous internet | Nothing but the public address | Accounts, enumeration, outage |
| Authenticated stranger | A valid account in their own organization | Another tenant's data; a higher role |
| Insider with a low role | Membership in a project or organization | More than their role allows; to hide what they did |
| Holder of a stolen token | One person's bearer token | That person's access, for as long as possible |
| Webhook owner | The ability to name a URL | The internal network behind it |
| Compromised dependency or CI | Code running in the build or the app | Secrets, a foothold |
| Compromised pod | Code execution in one container | Other services, the database, the cloud account |

## Trust boundaries

```
 internet ──(1)──> WAF ─ ALB ─ ingress ──> api ──(3)──> database
                                           │ │ └──(4)──> AI service ──> model provider
   browsers/clients                        │ └────(5)──> Auth service  (keys fetched over HTTPS)
                                           │ └────(6)──> webhook endpoints (customers' URLs)
                                           └─ outbox ─(7)─> SNS/SQS ──> Notification service ──> SES, Slack
 CI ──(8)──> registry ──> Git (GitOps) ──> cluster
```

## Threats

Each row: what is tried, what stops it, and what remains. Controls link to [security.md](security.md) rows and the decisions that justify them.

| # | Boundary | STRIDE | Threat | What stops it | What remains |
| --- | --- | --- | --- | --- | --- |
| T1 | 1 | S | Guess or stuff credentials | bcrypt; sign-in throttled per IP, per email and per account (`rate_limiting_spec`); the same 401 for an unknown address and a wrong password | Slow distributed guessing below the throttles. No breached-password check; no second factor |
| T2 | 1 | S | Use a stolen token | Only digests are stored (a database leak does not leak tokens); tokens expire unused after 14 days; rotation, listing and revocation of one's own sign-ins ([ADR 66](decisions.md)); the Auth service's access tokens last 15 minutes | A copied token works from anywhere until it expires, rotates or is revoked: not bound to a device, and a new sign-in place is not announced |
| T3 | 1 | S | Take over an account by password reset | Reset token valid 15 minutes, signs out every device, same answer for any address | Whoever controls the mailbox controls the account |
| T4 | 1 | E | Read or change another tenant's record by id (IDOR) | Records are found through the caller's policy scope; outsiders get 404, not 403; `tenant_isolation_spec` hits **every** route as an outsider and fails if a route is missing from its table | A new code path that bypasses `policy_scope`. `verify_policy_scoped` raises when forgotten, which turns the mistake into a failing test |
| T5 | 1 | E | Raise one's own role (mass assignment, forged parameters) | Role, owner and organization are never permitted attributes; the last owner cannot leave; roles are checked in policies per role | |
| T6 | 1 | S, I | Use an invitation meant for someone else | The token is signed, expires in 7 days, dies when accepted or revoked, and only works while signed in **as the invited address** | The API does not verify mailbox ownership at sign-up (the Auth service does in JWT mode) |
| T7 | 1 | I | Learn who is registered | Invitations and organization-project adds answer identically for known and unknown addresses | A personal-project add still says 404 for an unknown address; same-organization duplicates answer 422. Throttled, not closed |
| T8 | 1 | D | Exhaust the API | WAF; per-token and per-IP throttles; page size capped at 100; per-organization write budgets and per-endpoint throttles for the expensive reads; load shedding on the Puma backlog; request timeouts ([ADR 62](decisions.md)) | A distributed flood the WAF does not classify. The limits are chosen, not measured against a real attack |
| T9 | 1 | D | One tenant starves the others | Per-organization write budget (3,000 per 5 minutes), expensive-endpoint throttle | A tenant inside its budget but heavy on the database; the one writer is shared |
| T10 | 1 | T | Replay or double-submit a write | `Idempotency-Key`, scoped per user and fingerprinted ([ADR 55](decisions.md)); optimistic locking on records | Only for requests that send the key |
| T11 | 1 | E | Steer the AI into acting beyond the caller | AI features create tasks as the caller, through the same policies; the model's output is validated like untrusted input; per-user and per-project token budgets | Prompt injection can still make the model write misleading task text into a project the caller can already write to |
| T12 | 1 | R | An insider denies or hides a change | Append-only audit trail written in the same transaction as the change, attributed to the session's user | Append-only is enforced by the application (`readonly?`), not by the database: a database administrator can alter it. No log shipping to a separate store |
| T13 | 1 | E | Erase someone else's account | Needs the password, not only the token; 5 attempts an hour ([ADR 67](decisions.md)) | |
| T14 | 3 | I, T | Read or change data by reaching the database | Pods are default-deny for ingress and egress (NetworkPolicy; database traffic is allowed to the VPC CIDR on 5432 only, so any host in the VPC listening there is reachable, not just the database subnets), run as non-root with a read-only filesystem, no privilege escalation; the metadata endpoint is excluded from egress; credentials from Secrets Manager through External Secrets | The cluster's database connection is whatever `pg` negotiates; the app does not require or verify TLS (check `rds.force_ssl` on the cluster parameter group). Users' email addresses and webhook secrets are encrypted by the application ([ADR 69](decisions.md)); names, task text, invitation addresses, the audit trail and the outbox are not |
| T15 | 4 | S | Call the AI service without being the API | A bearer token compared in constant time; the NetworkPolicy lets only the API and worker reach it; the service refuses to start in production without a token | It is **one static shared secret**, rotated by hand (runbook), not bound to a caller or an expiry. Anyone who reads it from a pod's environment can call the service from inside the allowed network path |
| T16 | 5 | S, T | Forge a token by substituting keys | RS256 only, `exp` and `sub` required, issuer and audience checked; keys fetched over HTTPS, cached 10 minutes with stale-if-error and a rate-limited refresh | If the Auth service's private key leaks, anyone can mint tokens until it is rotated and the old public key removed (runbook) |
| T17 | 6 | I, E | Make the server call internal addresses through a webhook (SSRF) | The URL is resolved and refused if private, loopback, link-local or metadata, and re-checked at delivery; the pod's own egress policy also excludes the metadata address | A DNS answer that changes between the check and the connection; the delivery re-check narrows it, it does not eliminate it |
| T18 | 6 | S, I | Fake a webhook or replay it | `X-TaskApi-Signature` is an HMAC over timestamp and body, and receivers reject old timestamps; the secret is shown once and stored encrypted | Receivers must verify; there is **no rotation with an overlap** for a leaked webhook secret (recreate the webhook) |
| T19 | 7 | T, S | Inject or replay events on the queue | SQS access is by IAM (Pod Identity); consumers are idempotent by event id; malformed messages go to a dead-letter queue | An attacker with the API's IAM role can publish. Events are not individually signed |
| T20 | 8 | T, E | Ship malicious code | Dependency audit and Brakeman on every pull request; Dependabot; immutable image tags; deploys by Git (Argo CD) after a reviewed merge; CI assumes the cloud role through OIDC, with no stored cloud keys | **No secret scanning** in CI; no image signing or admission policy; a compromised dependency runs with the app's privileges |
| T21 | all | I | Secrets or personal data leak through logs and errors | Filtered parameters (`email`, `password`, tokens, secrets); events carry ids; errors are a code, a message and a request id; `consider_all_requests_local` off | Free text a user types into a title is logged only where an event names it; ingress access logs were not reviewed for client addresses |
| T22 | all | D | A dependency outage takes the API down | Circuit breakers, stale-if-error keys, timeouts, bulkheaded worker pools, read-only mode ([resilience.md](architecture/resilience.md)) | |
| T23 | demo | E | Abuse the public demo | Writes that touch other people (invitations, webhooks, sign-in lists, erasure) are refused; data is reset nightly | Anyone can fill it with junk until the reset |
| T24 | 3, 4 | I, E | Use the encryption keys without being the application, or read the keys the application holds | One key per purpose; the data key's policy refuses any request without the application's encryption context, from anyone; only the api (generate, unwrap) and worker (unwrap) have grants, on key ARNs, and the other services none; every request is in a KMS-only CloudTrail trail with alarms on decrypt volume, refusals and key changes ([ADR 70](decisions.md), [kms.md](aws/kms.md)) | The api role can unwrap anything it can name, and a process holds the unwrapped master and cached keys in memory. The wrapped master's plaintext is in Terraform's state. Revoking access reaches cached keys only after five minutes. **None of it has run on AWS** |
| T25 | 8 | E | Use the one-click workflow to change infrastructure | Manual start only; `apply` and `destroy` from `main` only; `destroy` needs the name typed again; no AWS key stored: a short-lived token for a role that trusts one repository's runs of one GitHub Environment, behind that Environment's reviewers ([ADR 71](decisions.md)) | The role is administrator, so whoever can approve in the Environment can do anything in the account. The Environment's protection rules are the control, and GitHub, not this repository, enforces them. **Never run** |
| T26 | 8 | S, E | Reach AWS through GitHub as someone other than the owner: a fork's pull request into `deploy.yml`, a stranger or a new collaborator pressing Provision, a mutable action tag, or a re-registered repository name | `deploy.yml` builds only a push to `main` by the owner; the roles trust one exact subject (this repository by its IDs, one Environment) and never "any run on main"; Environments accept `main` only, with the owner as reviewer and no administrator bypass; Provision's first step refuses any other account; actions that hold the token are pinned to commits; `github_settings.rb` reports any drift and any other collaborator ([ADR 72](decisions.md)) | AWS evaluates only `aud` and `sub`, so it cannot tell the owner from another collaborator: that rests on GitHub's settings. The owner is the only reviewer, so approval is a pause. The fork route was reasoned from documentation, not demonstrated. **None of it has run on real GitHub or AWS** |

## Zero trust, hop by hop

Nothing is trusted because of where it runs. What each hop actually proves:

| Hop | Who is asking | Proof | Network |
| --- | --- | --- | --- |
| Client to API | A person | Bearer token or short-lived JWT; per-record policy | WAF, ALB, TLS ends at the ALB |
| API to database | The API | Password from Secrets Manager | NetworkPolicy: egress to the VPC CIDR on port 5432 only |
| API to AI service | The API | **Shared static token** | NetworkPolicy; no mutual TLS |
| API to Auth service (keys) | The API fetching public keys | None needed; the keys are public and the tokens they verify are signed | HTTPS |
| Outbox to SQS, SQS to Notification service | The workload | IAM role through Pod Identity | HTTPS to AWS |
| Notification service to SES and Slack | The workload | SES credentials from Secrets Manager; the Slack URL is the secret | Egress to 443/587 |
| API to webhook endpoints | The API | HMAC signature the receiver verifies | Egress checked against private ranges |
| Prometheus to `/metrics` | The scraper | Bearer token (`METRICS_TOKEN`), compared in constant time, sent by the PodMonitor from the same Secret ([ADR 68](decisions.md)) | In-cluster only |
| CI to the cloud | The workflow | OIDC identity, short-lived role | |

The weakest hop is API to AI service: a long-lived secret that proves "someone with the secret" and not "the API". The upgrade is to replace it with the caller's **projected service-account token** (audience-bound, expiring, verified by the AI service against the cluster) or a signed token from the Auth service. It is not built because the NetworkPolicy already limits who can reach the port and the service has no database; the cost of doing nothing is stated in T15.

## What would change the ranking

Residual risks in the order worth fixing, with what each fix costs:

1. **Secret scanning in CI** (T20): an afternoon, and the repository's own security page already asks for it before outside contributions.
2. **Webhook secret rotation with an overlap** (T18): a migration, signing with both secrets for a window, and a rotation endpoint. The real cost is receivers having to accept two signatures during the window.
3. **Audit trail outside the application's reach** (T12): ship events to a store that the application's database role cannot alter (object storage with retention lock).
4. **Bound caller identity for the AI service** (T15), as above.
5. **Device binding or new-sign-in notification** (T2).
6. **Require TLS to the database** (T14): a parameter and a CA bundle; verify what the cluster already enforces first.

## Testing the model

A threat model that is never exercised is a document. T4 is the one a test enforces for every route; T1, T8 and T9 have request specs for their limits; T17 and T18 have specs for the guard and the signature. The rest are reviewed by reading. The failover drill and chaos exercises ([failure-domains.md](architecture/failure-domains.md)) test T22; no exercise tests T15, T16 or T19. Add one when the control changes.
