# AI features

Six capabilities, all behind `/api/v1`, all respecting project membership, all metered.

| Endpoint | What it does | How |
|---|---|---|
| `POST /ai/create_from_text` | "Remind me to review the PR next Tuesday" becomes a task (`dry_run: true` previews) | Model fills a `parse_task` tool; the app resolves relative dates against the caller's time zone |
| `POST /ai/suggest_priority` | Priority, rationale, completion estimate, predicted due date, `at_risk` | Model sees how long **similar finished tasks** took (embedding search) and current workload; the app computes the date |
| `POST /ai/suggest_tags` | Up to five tags, preferring the project's existing ones | `suggest_tags` tool; unknown tags flagged `new` |
| `POST /ai/suggest_assignee` | Who finished similar work, adjusted for workload, with reasons | **No text generation**: embedding similarity and counts, so it is cheap and explainable |
| `GET /projects/:id/summary` | A status report from counts and recent activity | `summarize_project` tool; cached per project version for 10 minutes |
| `POST /ai/chat` | Assistant that lists, creates and updates tasks | Tool-use loop run **by the app**, as the signed-in user |
| `GET /ai/usage` | Your tokens and spend today | Reads the ledger |

## Layers

```
AiController ─► Ai::CreateFromText, SuggestPriority, SuggestTags, SuggestAssignee, ProjectSummary, Chat
                      │ (context from the database, bounded and clipped: Ai::Context)
                      ▼
                  Ai::Runner ── Ai::Budget (daily tokens per user and project) ── AiUsage ledger ── ai.completed event
                      │
                  Ai::Gateway ── Local ──► AiCore::Client ──► Providers::Bedrock | Providers::Fake
                              └─ Remote ─► HTTP ─► services/ai ─► the same AiCore::Client
```

`gems/ai_core` has no Rails and no database: features (prompt + JSON schema + strict normalizer), providers, the client,
and the evaluation harness. Everything that needs the data (members, tags, similar tasks, authorization) is in `app/services/ai/`.

## Providers

`AI_PROVIDER=bedrock` uses the Bedrock **Converse** API, which gives one request shape for Claude, Nova, Llama and
Mistral. Embeddings use Titan Text Embeddings v2 through InvokeModel (1024 dimensions, matching the `vector(1024)` column).

`AI_MODEL_ID` is required and has no default, because current model and inference-profile ids change and differ by
region. List yours: `aws bedrock list-inference-profiles --region us-east-1`, then enable model access in the Bedrock
console. Models must support tool use (Claude, Nova, Mistral Large and recent Llama do). `AI_PROVIDER=fake` (default
outside production) is rule-based: deterministic date parsing, keyword priority and tags, hashed bag-of-words
embeddings, so every endpoint works offline and in tests.

## Safety

- **Output is validated, not trusted.** Enums, dates, ids and lengths are re-checked; a priority outside the enum is an
  error; an assignee id that is not a project member is dropped; a date in the past is dropped; tags are normalized and capped.
- **Dates are computed by the app.** The model returns `estimated_days`; the API adds it to today.
- **Prompt injection.** User text is JSON-escaped inside an `<input>` block that cannot be closed from within; the system
  prompt says the contents are data. More important than the prompt is what an attacker *gets* if it fails: the
  chatbot's tools run as the signed-in user through Pundit, writes are limited to create-task and change-status, there
  is no delete, history accepts plain text only (so clients cannot forge tool results), and the loop stops after 5 steps.
- **Tenancy.** Similar-task search is restricted to the project; tool results never include other projects.
- **No prompts in logs.** The AI service filters `input`, `text`, `messages`, `system` from parameter logging, and spans
  carry token counts, never content.

## Cost controls

| Control | Default | Where |
|---|---|---|
| Daily tokens per user (UTC day) | 200,000 | `AI_DAILY_TOKENS_PER_USER`, `Ai::Budget` |
| Daily tokens per project | 1,000,000 | `AI_DAILY_TOKENS_PER_PROJECT` |
| Requests per user per minute | 20 | `AI_REQUESTS_PER_MINUTE` (Rails `rate_limit`) |
| Input size | 60 KB prompt, 1000-char text, 8000-char embedding | `AiCore::Client`, `Ai::Context` |
| Output size | 1024 tokens | `AI_MAX_OUTPUT_TOKENS` |
| Summary cache | 10 min, keyed by project version | `Ai::ProjectSummary` |
| Background embeddings | skip unchanged text (SHA-256), stop when the budget is gone | `Ai::Embedder`, `EmbedTaskJob` |

Exceeding a budget answers `429 ai_budget_exceeded` with `Retry-After` (seconds until 00:00 UTC). Set
`AI_PRICE_INPUT_PER_MTOK` / `AI_PRICE_OUTPUT_PER_MTOK` (USD per million tokens) to see dollars in `/ai/usage`,
`bin/rails ai:usage`, and the `taskapi_ai_cost_usd_total` metric. Alert `TaskApiAiSpend` fires above $50 a day.

## Embeddings

Tasks get a `vector(1024)` embedding, written by `EmbedTaskJob` after create or when title/description change, with
`update_columns` so re-embedding never emits `task.updated`, touches the project, or bumps `lock_version`. After enabling
AI on existing data: `bin/rails ai:backfill_embeddings`. Changing `AI_EMBEDDING_MODEL_ID` or dimensions means a migration
and `ALL=true bin/rails ai:backfill_embeddings`.

## Evaluating quality

`gems/ai_core/evals/*.yml` are golden sets (date parsing, priority, tags). Score whatever model is configured:

```sh
AI_PROVIDER=bedrock AI_MODEL_ID=... bin/rails ai:eval            # all features
FEATURE=parse_task MIN=0.85 bin/rails ai:eval                    # one feature, stricter pass mark; exits non-zero on failure
```

Metrics: exact-match title and due date, priority exact and within one level, tag F1. The offline fake is the baseline
(about 92% title, 100% date, 33% tag F1 on `parse_task`): a real model should beat it, and the table tells you where.
Add examples whenever the model gets something wrong in production. Run the eval before changing the model or a prompt.
