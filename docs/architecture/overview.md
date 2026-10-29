# Architecture overview

The Task API started as one Rails 8.1 API-only application. This stage adds AI features inside it, makes it observable,
extracts three services behind it, and runs the whole thing on Amazon EKS. Each step is reversible by configuration.

```
                          Route 53 ──► WAF ──► ALB (TLS, path routing) ◄── ACM certificate
                                                   │
          /api/v1/{registrations,session,passwords}│  /api, /api-docs, /cable
                         ┌─────────────────────────┴───────────────┐
                         ▼                                         ▼
                  ┌─────────────┐   JWKS (public keys)     ┌──────────────────┐
                  │ Auth        │◄─────────────────────────│ Task API (api)   │  Projects, tasks, comments,
                  │ users,      │                          │  façade + core   │  tags, webhooks, audit, AI
                  │ JWT, refresh│                          │  Rails 8.1       │  orchestration, budgets
                  └──────┬──────┘                          └───┬───────┬──────┘
                         │ SNS                      HTTP+token │       │ SNS (task.*, project.*, …)
                         │                                     ▼       │
                         │                              ┌────────────┐ │        ┌───────────────────┐
                         │                              │ AI service │ │        │ Task API (worker) │
                         │                              │ Bedrock    │ │        │ Solid Queue jobs  │
                         │                              └────────────┘ │        │ embeddings, webhooks
                         ▼                                             ▼        └───────────────────┘
                  ┌──────────────────────────── SNS topic: task-api-<env>-events ──────────────────┐
                  └───────────────────────────────────────┬────────────────────────────────────────┘
                                                          ▼ filter: task.assigned, task.due_soon, …
                                                   SQS (+DLQ) ──► Notification service ──► SES / Slack

   Aurora PostgreSQL (pgvector): task_api* · auth · notifications        S3: attachments      Secrets Manager → External Secrets
   OpenTelemetry → collector → X-Ray │ Prometheus → Grafana │ CloudWatch (anomaly alarms) → SNS → PagerDuty / Slack
                                   └── RCA + remediation Lambdas (Bedrock) ──┘      Karpenter · KEDA · Argo CD · Argo Rollouts
```

## What runs where

| Component | Responsibility | Owns | Talks to |
|---|---|---|---|
| **Task API** (`app/`) | Projects, memberships, tasks, comments, tags, webhooks, audit log; AI orchestration (context, authorization, budgets, usage ledger); the public façade | `task_api_*` databases, S3 bucket | Auth (JWKS), AI service, SNS |
| **Worker** (same image, `bin/jobs`) | Solid Queue: embeddings, webhooks, SNS publishing, due-soon reminders, purges | — | the same database |
| **Auth** (`services/auth`) | Registration, sign-in, refresh-token rotation, password reset, JWKS | `auth` database | SNS |
| **AI service** (`services/ai`) | Stateless inference: features, tool-use turns, embeddings | nothing (no database) | Bedrock |
| **Notification service** (`services/notifications`) | Consumes events; sends email and Slack; deduplicates | `notifications` database | SQS, SES, Slack |
| **ai_core** (`gems/ai_core`) | The inference code, shared by the monolith (local gateway) and the AI service | — | Bedrock |
| **service_kit** (`gems/service_kit`) | JWT verification; JSON logs, metrics, tracing for services | — | — |

## Request paths

**A user creates a task by sentence.** Client → ALB → `api` verifies the JWT locally → `AiController` checks project
membership (Pundit) → `Ai::Runner` checks the user's daily budget → gateway calls the model (in-process, or the AI
service over HTTP) → the output is re-validated → the task is saved → `task.created` is published → `EmbedTaskJob`
embeds it in the background → a usage row and an `ai.completed` event record the cost.

**Someone is assigned a task.** The monolith saves the task, commits, emits `task.assigned`, and a job publishes it to
SNS. The filter delivers it to the notifications queue; the Notification service validates it, records its id (so a
redelivery does nothing), and emails the assignee using only the event's contents.

**An alarm fires.** CloudWatch → SNS alerts topic → PagerDuty / Slack, and in parallel the RCA Lambda (evidence → Bedrock
→ analysis posted next to the alarm) and, for queue alarms, the remediation Lambda (dry run unless enabled).

## Ways to run it

| Mode | Command | What you get |
|---|---|---|
| Monolith only | `bin/rails s` | Everything in one process; auth is local; AI uses the offline fake (no AWS needed) |
| Full stack on Docker | `docker compose up --build` | All services, Postgres, an AWS mock, a mail catcher, a gateway standing in for the ALB |
| Kubernetes on your laptop | `deploy/local/up.sh` | The production chart and images on `kind` |
| AWS | [aws/setup-guide.md](../aws/setup-guide.md) | EKS, Aurora, SNS/SQS, WAF, GitOps |

## The switches (all environment variables, all reversible)

| Variable | Values | Effect |
|---|---|---|
| `AUTH_MODE` | `local` (default) · `jwt` | Who issues and checks tokens. `jwt` turns the monolith into a verifier of the Auth service's tokens |
| `AI_GATEWAY` | `local` (default) · `remote` | Run inference in-process, or call the AI service |
| `AI_PROVIDER` | unset · `fake` · `bedrock` | Dev/test default `fake`; production stays off until `bedrock` is set |
| `NOTIFICATIONS_MODE` | `local` (default) · `remote` | Monolith mailers, or the Notification service |
| `EVENTS_SNS_TOPIC_ARN` | ARN or unset | Publish domain events to SNS |
| `ACTIVE_STORAGE_SERVICE` | `local` · `amazon` | Disk, or S3 (required on Kubernetes) |

## Where each phase lives

| Phase | Code | Config and docs |
|---|---|---|
| 1 AI in the monolith | `app/services/ai/`, `gems/ai_core/`, `app/controllers/api/v1/ai_controller.rb` | [ai.md](ai.md) |
| 2 Observability and early AIOps | `app/services/observability/`, `config/initializers/{logging,observability,opentelemetry}.rb` | `deploy/observability/`, `deploy/terraform/observability.tf`, [observability-and-aiops.md](observability-and-aiops.md) |
| 3 Microservices | `services/`, `gems/service_kit/`, `app/services/events/`, `app/services/external_auth.rb` | [microservices.md](microservices.md), [service-contracts.md](service-contracts.md) |
| 4 Containers and local Kubernetes | `Dockerfile`, `services/Dockerfile`, `docker-compose.yml` | `deploy/helm/`, `deploy/local/` |
| 5 EKS | — | `deploy/terraform/`, `deploy/k8s/platform/`, `deploy/gitops/`, `.github/workflows/` |
| 6 Advanced AIOps | `deploy/lambda/aiops/` | `deploy/terraform/aiops.tf`, `deploy/k8s/platform/cluster-config/` |
