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

- **`users` has two owners, by mode.** In JWT mode the Auth service owns the credentials and the monolith keeps a row per identity, linked by `auth_subject` (and `legacy_id` once, at cutover), kept in step at each sign-in. The name and email follow the Auth service; the monolith refuses to edit them (`409 managed_by_auth_service`). Work and Inbox reference that row by id. An erased person's row keeps the subject, and the monolith never makes a person of a subject that belongs to a tombstone ([ADR 79](../decisions.md)).
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

The only multi-owner change in the system is `DELETE /me`. In the monolith it is one transaction ([ADR 67](../decisions.md)). The person's data also lives in two other places, and since [ADR 79](../decisions.md#79-erasing-a-person-across-services-the-outbox-tells-the-auth-and-notification-services-the-tombstone-keeps-the-subject-and-jwt-mode-asks-the-auth-service-for-the-password) they are told:

| Step | Owner | Now |
| --- | --- | --- |
| 1. Erase in the monolith (tombstone, sign-ins, memberships, inbox, ...) and write `user.erased` to the outbox | Work, Inbox, Identity (local mode) | Done, atomically: the event exists if and only if the erasure committed |
| 2. Delete the identity and refresh tokens | Auth service (JWT mode) | **Built**: its own queue and consumer; deletes by the subject and by the Task API's id |
| 3. Delete delivery-log rows for the person | Notification service | **Built** for rows written since `recipient_id` was recorded; older rows (address only) age out under the 90-day retention |
| 4. Events in flight that carry the address | queue, outbox | Bounded by their retention (7 days after publishing, 4 and 14 days) and not scrubbed |

**How it works**, by the rules above:

- **Choreography through the outbox.** The event is `user.erased` and carries `user_id` and `auth_subject`, **not the address**: an event about forgetting someone must not be the newest copy of them. Its id is the person's (`user.erased:<id>`), so recording it twice stores it once.
- **Step 2:** the Auth service has a queue of its own (a subscription filtered on `user.erased`, kept 14 days, with a dead-letter queue) and a consumer in its Puma process, as the Notification service has. It deletes the account and, with it, every refresh token. An account imported at the cutover that has not signed in since has no linked subject, so the Task API's id (`legacy_id`) finds it too.
- **Step 3:** the Notification service records the id each recipient had when the row was written (`data.recipient.id`: the Task API's user id for a task email, the Auth service's uid for a password reset, hence a string) and deletes by both ids the event carries.
- **The window between 1 and 2 is closed on the monolith's side.** The tombstone keeps the identity's subject, and the monolith refuses a token whose subject belongs to a tombstone (`401`). Without that the Auth service's access tokens (15 minutes) and refresh tokens would make the person again, with their real address, at their next request: erasure in JWT mode would undo itself.
- **The password.** `DELETE /me` asks for it again so that a stolen token alone cannot erase an account. Where the Auth service owns the accounts the monolith asks it (an in-cluster endpoint with the same limit on attempts per address as signing in); if it cannot be reached the answer is `503` and nothing is erased.
- **No compensation.** Erasure cannot be undone, so there is nothing to roll back: the saga only moves forward, every step idempotent and retried from its queue until it succeeds. This is a *process manager with retries*, not a saga with compensations.
- **Why not call the other services from the request.** `DELETE /me` would then fail or hang whenever the Auth or Notification service is down, and a half-finished call would still need exactly this recovery logic. (The password check is the one call, because it must be answered before anything changes.)

**Not built:** the *record of progress* the first version of this page described, a table with a row per (person, step) and a `confirmed_at` filled from confirmation events. It needs the monolith to read a queue (it has no consumer today) and each service to publish a second event, to learn something the operator can already read from the queues: a failed step is a message in a dead-letter queue with an alarm, a service that is not taking events is an alarm on the age of its oldest message, and a lost event is sent again with `bin/rails erasure:publish` ([runbook](../runbooks/account-erasure.md)). What it would add is a per-person answer to "is this one gone everywhere", and it is the next step if that question is ever asked.

## Reviewing a boundary

Before moving a capability out, answer in writing: which table does it own, and who else reads it today? What events does it need, and are they already published? What is the rollback (a switch, as in the existing cutovers)? What does the person see if it is down (a degraded feature, as AI, or a failure, as Auth)? If the answers are "I do not know which tables", it is not ready.
