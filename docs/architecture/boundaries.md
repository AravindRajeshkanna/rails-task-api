# Boundaries: contexts, data ownership, and multi-step changes

Where the lines are between the parts of this system, who owns which data, and what to do when one change has to touch two owners. [microservices.md](microservices.md) says *how* capabilities were extracted and the rules that keep it from becoming a distributed monolith; this page states what the result is, where it still leaks, and how a change that spans owners is made safe. Contracts between the parts are in [service-contracts.md](service-contracts.md).

## The contexts

A context is a part of the business with its own language and its own reasons to change. "Task" means a unit of work in one and a row to embed in another.

| Context | Responsible for | Owns | Publishes | Consumes | Where it lives |
| --- | --- | --- | --- | --- | --- |
| **Identity** | Who a person is and how they prove it | In JWT mode, the Auth service's `users`, refresh tokens and signing key. In local mode, the monolith's `users` (credentials) and `sessions` | `user.password_reset_requested` | none | The Auth service when `AUTH_MODE=jwt`; otherwise inside the monolith |
| **Work** | Organizations, teams, projects, tasks, comments, tags, who may see what, and the history of changes | `organizations`, `organization_memberships`, `organization_invitations`, `teams`, `team_memberships`, `projects`, `memberships`, `project_teams`, `tasks`, `comments`, `tags`, `taggings`, `audit_events`, `idempotency_keys` | `task.*`, `project.*`, `comment.*`, `task.assigned`, `task.due_soon` | nothing from other contexts | The monolith. It stays ("Why Tasks and Projects stay" in [microservices.md](microservices.md)) |
| **Inbox** | What happened that a person should know | `notifications`, `notification_settings`, `notification_mutes` | `notification.created` on Action Cable | Work's events, in process | The monolith |
| **Integrations** | Telling customers' systems what happened | `webhooks`, `webhook_deliveries` | signed HTTP calls | Work's events, in process | The monolith. Named a candidate for extraction |
| **Intelligence** | Language-model features | The AI service: nothing (stateless). The monolith: `ai_usages` (the ledger and budgets) and `tasks.embedding` | `ai.completed` (local) | none | The AI service for inference; the monolith for the ledger and retrieval |
| **Messaging** | Getting email and Slack messages out, once | The Notification service: `deliveries`, `processed_events` | none | `task.assigned`, `task.due_soon`, `user.password_reset_requested`, from the queue | The Notification service |
| **Platform** | Moving work around reliably | `outbox_events`, the queue, cache and cable databases, Active Storage | none | none | The monolith, and AWS |

**Inside the monolith** the lines are conventions and tests, not a compiler: models belong to a context by the table above, the policies are where one context asks another "may this person?", and `spec/db/tenant_ownership_spec.rb` fails when a table has no owner. Nothing stops Work's code from reaching into Inbox's tables; a tool such as Packwerk would, and is not used. Extraction is the stronger boundary and is done only where the reason is strong (a different scaling shape or failure mode, a secret that should live elsewhere).

## Who may read and write what

1. **One writer per table.** The context that owns it. Others ask through its API or learn from its events.
2. **No shared databases between services.** The Auth service's `users` and the monolith's `users` are connected by a verified token, not by a join. The databases do share one Aurora cluster (see [failure-domains.md](failure-domains.md)); that is a hosting decision, not a licence to read across.
3. **An event carries what its consumer needs**, as a snapshot, so the consumer never calls back (`task.assigned` includes the recipient and the link).
4. **A consumer is idempotent** and deduplicates on the event id, because delivery is at least once and unordered.
5. **A synchronous call is for something a person is waiting on** (verifying a token, running a model). Everything else is an event.

### Where it leaks

Stating the rules is the easy half. The places they bend:

- **`users` has two owners, by mode.** In JWT mode the Auth service owns the credentials and the monolith keeps a row per identity, linked by `auth_subject` (and `legacy_id` once, at cutover), kept in step at each sign-in. The name and email follow the Auth service; the monolith refuses to edit them (`409 managed_by_auth_service`). Work and Inbox reference that row by id.
- **Addresses are copied into events and across services.** `task.assigned` carries the recipient's name and address so the Notification service never has to ask; the cost is that an address lives in the outbox, the queue and the delivery log ([data-protection.md](../data-protection.md)). A consumer that needs only an id would be better for privacy and worse for autonomy.
- **Integrations are not isolated from Work.** Webhooks consume the same events in the same process, so a slow subscriber is the monolith's problem, which is why delivery is a job on its own queue ([ADR 59](../decisions.md)).
- **Intelligence is split.** The model call is a service; the ledger of what it cost and the budgets that cap it are the monolith's, because they are enforced against Work's users and projects.
- **The audit trail records Work's changes by id** and outlives the records, which is its point, and which is also why erasure cannot delete a person from it ([ADR 67](../decisions.md)).

## When one change has to touch two owners

Most multi-step changes here stay inside one owner, in one database transaction, and need nothing more: creating a task and its audit event, accepting an invitation and the membership it grants. The tools that keep a change *atomic across a boundary without a distributed transaction* are the ones already in use:

- **The outbox.** An event exists if and only if the change that caused it committed, because both are written in the same transaction and a relay publishes later ([ADR 41](../decisions.md)).
- **Idempotent consumers and idempotency keys.** A repeated event or request does nothing the second time ([ADR 55](../decisions.md)).
- **Pull, not push.** The monolith creates the row for an identity at its first request with a valid token, instead of waiting to be told. No message can be lost, and no step can half-happen.
- **A call, then a write, in that order.** `POST /ai/create_from_text` asks the model first and writes tasks after; if the model fails, nothing was written and there is nothing to undo.

A **saga** is what is left when a business change really must happen in two places that cannot share a transaction, and being half done is a state someone can observe. Use one only then, and write down first: what the steps are, what *done* means, what happens if a step never succeeds, and whether each step can be undone. Two shapes: *orchestration* (one component tells each service what to do and tracks the outcome) is easier to see and to alert on; *choreography* (each service reacts to the previous one's event) has no center to fail but is harder to follow. With the outbox already in place, choreography is the cheaper start and an explicit status record makes it observable.

### A saga that exists: erasing a person across services

The only multi-owner change in the system today is `DELETE /me`. In the monolith it is one transaction ([ADR 67](../decisions.md)). The person's data also lives in two other places:

| Step | Owner | Today |
| --- | --- | --- |
| 1. Erase in the monolith (tombstone, sign-ins, memberships, inbox, ...) | Work, Inbox, Identity (local mode) | Done, atomically |
| 2. Delete the identity and refresh tokens | Auth service (JWT mode) | **Not built**: the Auth service has no delete path |
| 3. Delete delivery-log rows for the address | Notification service | **Not built**: bounded by 90-day retention; the service stores the address, not an id |
| 4. Events in flight that carry the address | queue, outbox | Bounded by their retention (7 and 14 days) |

**What a complete version would look like**, by the rules above:

- **Choreography through the outbox.** Step 1 also writes a `user.erased` event to the outbox in the same transaction (today it is only a local log line). The event carries `user_id` and `auth_subject`, **not the address**.
- **Step 2:** the Auth service consumes it, deletes the identity and its refresh tokens by subject, and publishes `user.identity_erased`.
- **Step 3:** the Notification service must be able to find its rows by id, so it starts storing `recipient_id` (already in the event's `data.recipient.id`) next to the address; it then deletes by id and publishes `user.deliveries_erased`. Rows written before that change age out under retention.
- **No compensation.** Erasure cannot be undone, so there is nothing to roll back: the saga only moves forward, every step idempotent and retried until it succeeds. This is a *process manager with retries*, not a saga with compensations.
- **A record of progress:** a small table, one row per (user, step) with `confirmed_at`, filled as the confirmation events arrive. *Done* means all rows confirmed. A step pending for more than a week raises a ticket, because an erased person who is still in a delivery log is a promise not kept.
- **Why not call the other services from the request.** `DELETE /me` would then fail or hang whenever the Auth or Notification service is down, and a half-finished call would still need exactly this recovery logic.

**Not built**, and the reason is proportion: the monolith's part is the large majority of what is held, the other two have bounded retention, and the first user of JWT mode would be the trigger to build step 2. This section is the design to start from, so that it is built once and by the rules.

## Reviewing a boundary

Before moving a capability out, answer in writing: which table does it own, and who else reads it today? What events does it need, and are they already published? What is the rollback (a switch, as in the existing cutovers)? What does the person see if it is down (a degraded feature, as AI, or a failure, as Auth)? If the answers are "I do not know which tables", it is not ready.
