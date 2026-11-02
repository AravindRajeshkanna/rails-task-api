# The whole platform on your laptop: Docker Compose and kind

Two ways to run every service (the API and its worker, Auth, AI, Notifications) with Postgres, a mock of AWS's SNS and SQS, and a mail catcher: `docker compose` (nginx plays the load balancer) and `kind` (the production Helm chart and images behind an nginx Ingress). **[`deploy/local/verify.sh`](../deploy/local/verify.sh) is the definition of "it works"**: it uses the stack as a client would, through the one address a client has, and is the same script for both.

Both were first run on 2026-11-02 ([roadmap 10](roadmap.md#roadmap-10-running-docker-compose-and-kind-for-the-first-time), [ADR 74](decisions.md)). They did not work. This page says how to run them, what the script proves, what the first run found, and what it does not prove.

## Run it

You need Docker (Docker Desktop's virtual machine had 3.8 GiB when this was measured, and that was enough for either one), `curl` and `jq`; for `kind` also `kind`, `kubectl`, `helm` and `openssl`. **Both publish port 8080: stop one before starting the other.**

```sh
# Docker Compose
{ printf 'RAILS_MASTER_KEY=%s\n' "$(cat config/master.key)"
  printf 'AUTH_JWT_PRIVATE_KEY=%s\n' "$(openssl genrsa 2048 2>/dev/null | base64 | tr -d '\n')"; } > .env   # .env is git-ignored
docker compose up -d --build
deploy/local/verify.sh                 # gateway :8080, mail catcher :8025
docker compose down -v                 # -v also removes the database

# kind
deploy/local/up.sh                     # a 3-node cluster, the four images, the chart; safe to run again
kubectl -n task-api port-forward svc/mailpit 8025:8025 &    # the script reads the caught mail from here
deploy/local/verify.sh                 # the Ingress is on :8080 as well
deploy/local/up.sh down
```

`docker compose --profile observability up -d` adds Prometheus (:9090), Grafana (:3001) and Jaeger (:16686). **Traces appear only if the services are told where to send them:** put `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318` in `.env`.

## What `verify.sh` proves

It registers two people, and exits 0 only if all of these hold (25 checks; `API_URL`, `MAIL_URL`, `WAIT_SECONDS` change the addresses and patience):

| Group | Checks |
| --- | --- |
| The edge | the API answers behind the address (its own 401 to a request without a token); the Auth service answers behind the same address; the API documentation is served; `/metrics` is not readable from outside |
| Auth service | a registration returns a token (twice); sign-in returns a refresh token; a wrong password is refused |
| API | the Auth service's token is accepted (the API fetched its keys over the network), a tampered one is refused; a project, a membership and a task assigned to the second person are written, and read back by them |
| Events | the assignment reaches the assignee's inbox **and their mailbox** (API → outbox → worker → SNS → SQS → Notification service → SMTP); a password-reset email reaches the first person, its link sets a new password, the new password signs in and the old one no longer does |
| AI service | a priority suggestion comes back (the API has no model of its own here, so it was the AI service that answered) |

A check that cannot fail proves nothing, so each component was stopped in turn (Compose: `docker compose stop`; kind: `kubectl scale --replicas=0`). The result was the same on both, and it shows what each check exercises:

| Stopped | Checks that failed |
| --- | --- |
| `ai` | the priority suggestion (1) |
| `worker` | the assignee's email (1); their inbox still works, because that part runs inside the API |
| `notifications` | the three email checks |
| `aws` (Compose only) | the three email checks |

## What it measured

| | Docker Compose | kind |
| --- | --- | --- |
| Memory, at rest once up | 1.05 GiB (nine containers) | 2.4 GiB (three node containers) |
| Images, cold build | 272 s for the four | (the same images) |
| Up from nothing | about 95 s with a warm build cache; 21 s when started again with the database kept | 257 s (cluster, load into three nodes, install); 85-96 s run again over a running cluster |
| Kubernetes | | v1.37.0 (kind 0.33's default node image); Helm 4.0.4; ingress-nginx v1.12.1 |
| After a restart | the rows written before it were there | the rows written before Postgres restarted were there |
| One API pod replaced | | back and serving in 12 s; about 8 s of outage, because the local overlay runs one replica |

On Compose, the observability profile also ran: Prometheus scraped all four services, Grafana loaded its datasource and the "Task API" dashboard, and 17 of the dashboard's 20 queries returned data (none errored).

## What the first run found

Nine faults, each fixed and each held by a test that fails without the fix. None was visible to CI, which builds the images and renders the chart but never starts anything.

| # | Where | What happened | Fix |
| --- | --- | --- | --- |
| 1 | Compose | `docker compose up --build` failed on the first run: `image "docker.io/task-api/api:local": already exists`. `api`, `migrate` and `worker` each built the same tag, and on the containerd image store (Docker Desktop's default) the three exports collide. Three failures in three tries, then three passes | Only `api` builds; the others `pull_policy: never` |
| 2 | Compose | `aws` could not start on a Mac: host port 5000 belongs to the AirPlay Receiver | Published on 5555 |
| 3 | Compose | Found while looking at ports: Postgres (superuser password `postgres`), the AWS mock (no authentication), the mail catcher and Grafana (anonymous **Admin**) were published on every network interface | The backing services bind to 127.0.0.1 |
| 4 | Compose (seen). The Helm migration Job and Kamal's entrypoint run the same `db:prepare` (reasoned, not run) | `migrate` exited 1 on every first start. `db:prepare` seeds a database it has just filled, and `db/seeds.rb` aborts in production. CI never saw it: the load test copies an already-seeded database. By the same reasoning, the first deploy to an empty Aurora cluster would fail the same way | `seeds: false` for the production primary in `config/database.yml`. A hand-run `bin/rails db:seed` in production still aborts |
| 5 | Compose and kind | The Notification service died on its first email. In production it always asks the relay to authenticate (`authentication: :plain`), and Mailpit has no login: Net::SMTP raised `SMTP-AUTH requested but missing user name`. The error is not one the consumer retries, so it ended the consumer thread, and the Puma plugin then stops the process on purpose. **Nothing was logged**: nothing in the repository subscribes to `Rails.error`. The container just exited 143 | `ServiceKit::SmtpSettings` signs in only when `SMTP_USERNAME` is set, and `Consumer.report_crash` writes the error, with the top of its backtrace, to the log before the process stops |
| 6 | kind | `localhost:8080` refused connections. `up.sh` applied the "examples/ingress" manifest from kind.sigs.k8s.io, which is now the generic one: the controller can run on any node, and it ran on a worker, while `kind-cluster.yaml` forwards 8080 to the control-plane node only | The kind build of ingress-nginx, at a fixed version, which pins the controller to that node |
| 7 | kind (Helm 4) | `helm upgrade --install api` failed: `duplicate entries for key [name="SKIP_DB_PREPARE"]`. The release's values set it, and the migration Job's template added it again. Server-side apply (Helm 4's default) refuses a repeated name; client-side apply, which Argo CD uses unless told otherwise, is generally said to accept it with the later entry winning (not tested here) | The Job's template skips the key it sets itself |
| 8 | kind | The API pod never became ready (CrashLoopBackOff). Roadmap 7 added a second `/readyz` check, `encryption`, which fails with no key source, and `up.sh` sets none. [kms.md](aws/kms.md) says docker compose and Kamal set `credentials`; `kind` was not in the list | `up.sh` sets it for the API and the worker |
| 9 | kind | Every span export failed and logged an error: the chart's default collector address does not exist locally | `up.sh` clears the endpoint |

## Found and not fixed

- **The AI service's spans never reach Jaeger**, although its tracer is configured exactly like Auth's (same exporter, same endpoint, no errors anywhere). Not diagnosed. Auth, Notifications and the API do appear.
- **Three of the dashboard's 20 queries are empty on Compose.** Two use recording rules (`taskapi:http_error_ratio:rate5m`, `taskapi:queue_oldest_ready_age_seconds:max`) that only the Kubernetes PrometheusRule defines; Compose's Prometheus loads no rules. Not diagnosed for `taskapi_queue_ready_jobs`.
- **With the AWS mock stopped, "ask for a password reset" still answers 202** and the email never comes. That is the deliberate "always 202" (so the endpoint cannot be used to find out who has an account), but it means a broken event bus is invisible to the caller. I did not test whether the event is retried when the mock returns.
- **The monolith's production SMTP settings have the same shape as fault 5** (always authenticate). Neither stack exercises them, because both send mail through the Notification service, so I left them.
- **Compose has no restart policy for the Notification service**, whose consumer exits on a crash expecting an orchestrator to restart it. The crash is now in the log; it still stays down.

## What this does not prove

- **One machine**: an Apple-silicon Mac, Docker Desktop, Docker Engine 29.1.3 with the containerd image store. Fault 1 was reproduced only there; the fix is reasoned for the classic store, not run on it. Not run on Linux or amd64.
- **Helm 4 only.** CI and Argo CD use Helm 3, which renders the same YAML (the new spec renders with whichever is installed), but I did not run Helm 3.
- **The local overlay is not production.** One replica, no autoscaling, PodDisruptionBudgets, NetworkPolicies, External Secrets, Rollouts, KEDA or ALB, and the chart's cloud values are overridden. That the chart installs on `kind` says nothing about those templates.
- **No KMS, no SES, no Bedrock**: keys come from Rails' credentials, mail goes to Mailpit, the AI provider is the offline fake.
- **Not in CI.** The faults above all slipped past CI because nothing starts the stack there. A job that runs `docker compose up` and `verify.sh` would catch this class; it needs a GitHub runner to try, and I could not here ([roadmap, Next](roadmap.md#next)).
- **The negative controls were done by hand**, and `verify.sh` has no spec of its own beyond `shellcheck`, a parse under macOS's bash 3.2, and checks that it asks only for paths both stacks route.

## When it does not start

| Symptom | Cause |
| --- | --- |
| `ports are not available ... 8080` | Compose and kind both use 8080: `docker compose down` or `deploy/local/up.sh down` first |
| `verify.sh` says `429` on registration | Sign-up is limited to 10 an hour per client (about five runs). Compose: `docker compose restart auth`; kind: `kubectl -n task-api rollout restart deploy/auth` |
| `verify.sh` fails only the email checks | Read the Notification service's log: `docker compose logs notifications` or `kubectl -n task-api logs deploy/notifications`. A `notification.consumer_crashed` line says why it stopped |
| The kind cluster was made by an older `up.sh` and `up.sh` fails on `ingress-nginx-admission` | Jobs cannot be edited: `deploy/local/up.sh down`, then up again |
| `docker compose` cannot find `RAILS_MASTER_KEY` | There is no `.env`: see the commands above |
