# Runbook: rotating secrets

> **Never run against AWS.** This is written from the configuration (`deploy/terraform/secrets.tf`, the Helm chart, the services' code), and nothing here has been rehearsed. Two procedures existed before (the JWT key and the AI token, in the setup guide's day-2 table) and are restated here with a corrected cache timing. Rehearse in staging before you need one in production, and write down what surprised you.

Use this page for scheduled rotation and, with the "Suspected leak" section, for an incident. What a leaked secret allows is in [threat-model.md](../threat-model.md).

## How a secret reaches a pod

```
Terraform (random_password, tls_private_key)  ->  Secrets Manager  task-api/<env>/<service>   (one JSON document per service)
                                                        |  replicated to the standby region
                                                        v
                                    External Secrets (refresh every 1h)  ->  Kubernetes Secret <service>
                                                        v
                                         envFrom in the Deployment  ->  environment variables, read AT PROCESS START
```

Two consequences shape every procedure below:

1. **A running pod never sees a change.** Every rotation ends with a rolling restart (`kubectl -n task-api rollout restart deploy/<name>`, or `kubectl argo rollouts restart <name> -n task-api` where the canary Rollout is enabled, which is `staging` and `prod`). External Secrets takes up to an hour to copy the new value; force it: `kubectl -n task-api annotate externalsecret <service> force-sync=$(date +%s) --overwrite`.
2. **Terraform does not fight you, and does not help you.** The secret versions have `ignore_changes = [secret_string]`: a value you rotate by hand survives later applies, and a value Terraform derives (the SES SMTP password) is **not** copied into the secret for you.

A helper for the one-key-in-a-JSON-document edit (the value goes through the environment, not the command line, so it stays out of `ps` and history):

```sh
ENV=prod
set_key() {   # set_key <service> <json key>      the new value is in $NEW_VALUE
  local tmp; tmp=$(mktemp)
  aws secretsmanager get-secret-value --secret-id "task-api/$ENV/$1" --query SecretString --output text \
    | KEY="$2" python3 -c 'import sys, os, json; d = json.load(sys.stdin); d[os.environ["KEY"]] = os.environ["NEW_VALUE"]; print(json.dumps(d))' > "$tmp"
  aws secretsmanager put-secret-value --secret-id "task-api/$ENV/$1" --secret-string "file://$tmp"; rm -f "$tmp"
}
```

In the standby region the secrets are read-only replicas. To write after losing the primary region, promote them first ([regional failover](regional-failover.md)).

## Inventory

| Secret | Lives in | Read by | If it leaks | Section |
| --- | --- | --- | --- | --- |
| Session tokens (people's) | digests in the `sessions` table | the API | one person's access | [1](#1-session-tokens) |
| Auth service JWT private key | `task-api/<env>/auth` `jwt_private_key` | Auth service (signs); everyone else verifies with its public key | anyone can mint a token for anyone | [2](#2-the-auth-services-signing-key) |
| `AI_SERVICE_TOKEN` | `task-api/<env>/ai-service-token` | API, worker (callers), AI service (verifier) | AI spend, from inside the network | [3](#3-ai_service_token) |
| `METRICS_TOKEN` | `task-api/<env>/api` `metrics_token` | API (verifier); the PodMonitor sends it | read the metrics | [4](#4-metrics_token) |
| Database passwords | `task-api/<env>/{api,auth,notifications}` `database_password` | each service | read and write that service's database | [5](#5-database-passwords) |
| Rails credentials: `secret_key_base`, encryption keys | `config/credentials*.yml.enc`, key in `task-api/<env>/api` `rails_master_key` | API, worker | forge signed links; decrypt webhook secrets | [6](#6-the-rails-credentials) |
| SES SMTP username and password | `task-api/<env>/notifications` `smtp_*` | Notification service | send mail as the platform | [7](#7-ses-smtp-credentials) |
| Slack webhook URL | `task-api/<env>/notifications` `slack_webhook_url` | Notification service | post to the channel | [8](#8-the-slack-webhook-url) |
| Customers' webhook signing secrets | `webhooks.secret`, encrypted | the delivery job | forge events to that customer | [9](#9-a-customers-webhook-signing-secret) |
| CI's cloud access | none stored: OIDC to a role | GitHub Actions | nothing to rotate | [10](#10-ci-to-aws) |
| Aurora master password | managed by RDS in Secrets Manager (`manage_master_user_password`) | operators | full database access | RDS rotates it; nothing to do |

## 1. Session tokens

People rotate their own: `POST /api/v1/session/rotate` ([ADR 66](../decisions.md)). To end **every** sign-in at once (a database leak is not a token leak, because only digests are stored; this is for a suspicion that tokens were seen elsewhere):

```sh
kubectl -n task-api exec deploy/api -- bin/rails runner 'puts Session.delete_all'
```

Everyone must sign in again. In JWT mode the monolith's sessions are not the credential; revoke refresh tokens in the Auth service instead.

## 2. The Auth service's signing key

Tokens carry the key id (`kid`). The Auth service publishes every key it knows at its JWKS endpoint, and verifiers fetch them, so a key can be replaced without a moment when tokens are refused.

1. Generate: `openssl genrsa 3072 | base64 | tr -d '\n'` (the secret holds the base64 of the PEM).
2. **Keep the old public key trusted.** Put the old key's public PEM into `AUTH_JWT_PREVIOUS_PUBLIC_KEYS` (a JSON array of PEMs) on the Auth service (`deploy/helm/values/auth.yaml`; public keys are not secrets) and merge; Argo CD syncs it.
3. `NEW_VALUE=<the base64 key> set_key auth jwt_private_key`, force-sync the `auth` ExternalSecret, restart `auth`. From now on it signs with the new key and lists both.
4. The monolith needs nothing: on the first token with an unknown `kid` its verifier refetches the keys (at most once every 30 seconds).
5. **Retire the old key** by deleting it from `AUTH_JWT_PREVIOUS_PUBLIC_KEYS` after the last token signed with it has expired (15 minutes) **plus the verifier's key cache (10 minutes)**. The setup guide used to say 5 minutes for the cache; the verifier's default is 600 seconds.

If the old key is *compromised*, do step 5 immediately and restart the verifiers (`api`): the cache is in the process, and a verifier that cannot reach the Auth service keeps trusting the keys it has for up to 24 hours (`max_stale`), so a restart is how you make removal take effect now. Tokens already issued stop working; clients that refresh on 401 recover with their refresh token.

## 3. `AI_SERVICE_TOKEN`

One value, read by two sides. `NEW_VALUE=$(openssl rand -hex 24)`, write it to `task-api/<env>/ai-service-token` (`aws secretsmanager put-secret-value --secret-id task-api/$ENV/ai-service-token --secret-string "$NEW_VALUE"`), force-sync the ExternalSecrets of `api`, `worker` and `ai`, then restart **`ai` first, then `api` and `worker`** in quick succession.

Expect: between the restarts the two sides disagree, the AI service answers 401, and the AI endpoints answer **`502 ai_error`** ("AI service answered 401"). A 401 is not one of the failures the `ai_service` circuit breaker counts (it counts only `Ai::Unavailable`), so it does not open and calls keep being tried; those 502s are 5xx and spend a little of the availability error budget ([slo.md](../slo.md)). Nothing outside the AI endpoints is affected. There is no overlap window (the service accepts one token); accepting two for a while would make this invisible and is not built.

## 4. `METRICS_TOKEN`

`NEW_VALUE=$(openssl rand -hex 24) set_key api metrics_token`, force-sync the `api` ExternalSecret, restart `api`. The PodMonitor reads the same Kubernetes Secret, so Prometheus starts sending the new token as soon as the Secret changes, while the pods demand it only once restarted: scrapes return 403 for the minutes in between. `TaskApiNotScraped` waits 15 minutes before it opens a ticket, so a rotation that finishes inside that window raises nothing; one that stalls does ([slo.md](../slo.md#when-the-numbers-stop-arriving)).

## 5. Database passwords

Postgres holds one password per role, so there is a moment when new connections can fail whatever the order. The order that keeps it short:

1. Generate and store the new password: `NEW_VALUE=$(openssl rand -hex 24) set_key api database_password`; force-sync.
2. From inside the VPC (the bootstrap script shows how): `ALTER ROLE <service> PASSWORD '<new>';`
3. **Straight away**, restart the service. Old pods keep their open connections (a password is checked when a connection is made), but any connection they open afresh with the old password fails. A pod *started* with a password the database does not accept never passes its readiness check (`/readyz` runs a query), so a rolling restart that gets the order wrong stalls instead of serving errors ([ADR 63](../decisions.md)).

Do `api` and `worker` together (they share a database and a secret). A rotation with no failed connection at all needs two roles that take turns; that is not built.

## 6. The Rails credentials

The API's `config/credentials.yml.enc` holds `secret_key_base`, the Active Record encryption keys and an SMTP fallback; `RAILS_MASTER_KEY` decrypts it. Back up the master key outside AWS.

- **`secret_key_base`.** Change it with `bin/rails credentials:edit` (the repository has one credentials file, `config/credentials.yml.enc`; add `--environment production` if you have moved to per-environment credentials, as the setup guide recommends), deploy. Everything signed with it stops verifying: outstanding invitation links (7 days), password reset links (15 minutes) and signed file URLs. People ask again. There are no cookies and no server-side session store keyed by it.
- **Encryption keys (webhook secrets).** Add the new `primary_key` while keeping the old one in the list Active Record decrypts with, deploy, then re-encrypt every row and only then remove the old key:

  ```ruby
  Webhook.find_each(&:encrypt)   # bin/rails runner; re-saves each secret under the current key
  ```

  **Check in staging, before production, which key encrypts when two are listed**: encrypt a value, remove the old key from the list, and confirm it still decrypts. Losing the old key before re-encrypting makes every webhook secret unreadable, and the only repair is for each customer to recreate the webhook.
- **The master key itself.** There is no re-key command. Copy the decrypted credentials out (`bin/rails credentials:show`), create a new credentials file with a new key (`bin/rails credentials:edit` with the old `credentials.yml.enc` and `master.key` moved aside), paste, `NEW_VALUE=<new key> set_key api rails_master_key`, deploy `api` and `worker`. Rehearse; it is the one step here that can lock you out.

## 7. SES SMTP credentials

The SMTP password is derived from an IAM access key made for one purpose (send mail). `terraform apply -replace='aws_iam_access_key.ses_smtp[0]'` makes a new one, then **copy the new values into the secret yourself** (Terraform will not, because of `ignore_changes`): the username is the new key's `id` and the password is its `ses_smtp_password_v4`, both in the state (`terraform show -json` includes sensitive values; treat the output as a secret). `set_key notifications smtp_username`, `set_key notifications smtp_password`, force-sync, restart `notifications`. Delete the old access key afterwards. Test by assigning a task and watching the email arrive.

## 8. The Slack webhook URL

Revoke the old URL in Slack, create a new one, `set_key notifications slack_webhook_url`, force-sync, restart `notifications`.

## 9. A customer's webhook signing secret

A webhook's secret is shown once, when it is created. There is **no rotation with an overlap**: the only way to change it is to delete the webhook and create another, and the receiver must switch at the same moment (events in between are signed with a secret the receiver does not know). A leaked secret means deleting the webhook now. A rotation endpoint that signs with both secrets for a window is the missing feature ([threat-model.md](../threat-model.md), T18).

## 10. CI to AWS

GitHub Actions assumes a role through OIDC; there is no stored cloud key to rotate. If the repository or an environment is renamed or transferred, check the role's trust policy still names the right one.

## Suspected leak: what to do first

Rotate in this order, the most powerful first, and stop when you know the leak was narrower:

1. Anything that reads or writes the database: the Rails master key and the database passwords (5, 6).
2. The Auth signing key (2): it lets an attacker be anyone.
3. Session tokens (1) if tokens were exposed.
4. The AI token (3): it costs money. Per-user and per-project budgets bound the damage meanwhile.
5. The rest.

Then look for use: the audit trail (who changed what), the API's logs for the window, `taskapi_ai_requests_total` for unexpected AI traffic. Record what was exposed, for how long and what was rotated.

## Cadence

Not enforced by anything yet. A sensible one: the JWT key and the AI token every quarter, as a rehearsal as much as a precaution; the database passwords and SMTP credentials yearly; everything involved whenever someone who could read the secrets leaves. Automated rotation (Secrets Manager rotation functions) would replace the manual steps for the database passwords; it is not built, and the two-role scheme above is what it would need.

## Not covered

KMS key rotation (AWS rotates its managed keys yearly), TLS certificates (ACM renews its own), the Terraform state bucket (its contents include the generated secrets: keep it private and encrypted), and secret scanning in CI (not built; [security.md](../security.md)).
