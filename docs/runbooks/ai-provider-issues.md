# Runbook: AI provider problems

**Alerts:** `TaskApiAiErrors` (> 20% of model calls failing), `TaskApiAiSpend`, rising `ai_unavailable` / `ai_invalid_response` / `ai_budget_exceeded` responses.

## Symptoms and meaning

| Response from the API | Meaning | Who acts |
|---|---|---|
| `503 ai_not_configured` | No provider set (production stays off until `AI_PROVIDER=bedrock`), or `AI_SERVICE_URL` missing | Operator: configuration |
| `503 ai_unavailable` (+`Retry-After: 5`) | Bedrock throttling/timeouts or the AI service unreachable | Usually transient; clients retry |
| `502 ai_invalid_response` | The model answered, but not in the required structure | Rare; if frequent, the model or prompt changed: run `ai:eval` |
| `429 ai_budget_exceeded` | That user or project used its daily token budget (resets 00:00 UTC) | Working as intended; raise the limits if the budget is wrong |
| `429 rate_limited` | More than `AI_REQUESTS_PER_MINUTE` from one user | Working as intended |

## Triage

1. **Bedrock errors:** the AI service logs `ai.completed` with `outcome=error` and the exception class. `AccessDeniedException` =
   model access not granted or the Pod Identity role lost its policy; `ThrottlingException` = quota (request an increase for the
   model's tokens/min in Service Quotas, or move to a cross-region inference profile); `ValidationException` = wrong model id / a model
   that does not support tool use.
2. **A model or prompt change?** `AI_MODEL_ID=… bin/rails ai:eval` against the golden sets from your machine; compare with the last good run.
3. **Spend:** `bin/rails ai:usage` (today by feature), `taskapi_ai_cost_usd_total`, or Cost Explorer for Bedrock. One user dominating? Their
   budget caps them at `AI_DAILY_TOKENS_PER_USER`; for abuse, revoke the account.
4. **Degrade rather than fail:** the features that do not need generation (assignee suggestion, similar tasks) keep working with embeddings;
   everything else answers 503. To switch AI off entirely: `AI_GATEWAY=remote` with no AI service, or unset `AI_PROVIDER` on the AI service
   (`ai_not_configured`).

## The circuit breaker (`TaskApiCircuitOpen`)

Two breakers guard the model: `ai_provider` (this app calling Bedrock in-process) and `ai_service` (this app calling the AI service). After five failures in a row (timeouts, connection errors, a 5xx or the provider's own throttling) a breaker opens: for 30 seconds, then 60, doubling up to 5 minutes after each failed probe,
calls to the AI fail **at once** with `503 ai_unavailable` and a `Retry-After` of what is left of the pause, instead of each holding a thread for the full timeout. After the pause one call is let through to find out; if it works the breaker closes. Everything that is not AI is unaffected.

- `taskapi_circuit_breaker_state{breaker}` is 0 (closed), 1 (half-open) or 2 (open); `taskapi_circuit_breaker_transitions_total{breaker,to}` counts the changes. A breaker flapping open and closed every minute means a provider that is half-working: look at its latency, not at the breaker.
- It is per pod: each pod learns of an outage by itself within five calls, and needs nothing else to be up to do so. During an outage expect up to five failing calls per pod before the pods stop calling.
- To force it closed (a false alarm, the provider is fine): restart the pods. There is deliberately no admin switch; a switch that closes a breaker during a real outage is how an outage is made worse.

