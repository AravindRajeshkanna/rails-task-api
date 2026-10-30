# Data protection: what we hold about people, for how long, and how it leaves

Written for the engineers and operators who run this system and for whoever reviews it. It describes what the code does today, including where it falls short; it is not legal advice, and it does not claim compliance with any regulation. Decisions and their trade-offs are in [ADR 67](decisions.md); the threats this defends against are in [threat-model.md](threat-model.md).

The rules the design follows: keep the least that the product needs; give every kind of personal data a retention that a job enforces, not one that a document promises; make deletion a feature a person can use, with a stated list of what it does not reach; keep personal data out of logs, events and metrics (they carry ids).

## What is held

"Person" means a user. Third parties named in free text (a task that says "call Grace") are covered by the free-text row.

| Data | Where | Why | Kept for | When the person is erased |
| --- | --- | --- | --- | --- |
| Name, email address, password hash (bcrypt) | `users` in the monolith (in JWT mode also the Auth service's `users`) | Identify, sign in, address notifications | Until erased | Name becomes `Deleted user`, address `erased-<id>@erased.invalid`, hash removed. **The Auth service's copy is not reached** (see "Not built") |
| Avatar image | Active Storage (S3) | Profile | Until replaced or erased | Purged |
| Sign-ins: token digest, IP address, user agent | `sessions` | Authenticate; show "where am I signed in" | 30 days at most, 14 days unused; ended by sign-out, rotation, revocation; pruned daily | Deleted |
| Project, organization and team memberships, with roles | `memberships`, `organization_memberships`, `team_memberships` | Access control | While a member | Deleted |
| What they wrote: task titles and descriptions, comments, attachments | `tasks`, `comments`, Active Storage | The project's own record | With the project; an archived task or project is purged after 30 days | **Kept**, attributed to `Deleted user`: it belongs to the project, not to the author. Free text can contain personal data; project members can delete individual items through the API |
| Assigned tasks | `tasks.assignee_id` | Who is doing what | Until reassigned | Unassigned |
| Inbox | `notifications` | Tell people what happened | Read: 30 days. Unread: 180 days | Deleted |
| Notification preferences | `notification_settings`, `notification_mutes` | Digest and mute choices | Until erased | Deleted |
| Invitation addresses (of anyone, registered or not) | `organization_invitations` | Invite by address | Until **90 days after** it concluded (accepted, revoked or expired) | Invitations addressed to the person are deleted; their address is also removed from the audit trail |
| Audit trail | `audit_events` | Accountability: who changed what | **Indefinitely**, append-only | `actor_id` keeps pointing at the tombstone. The trail holds the changed values of audited records (tasks, projects, organizations, teams, roles): task titles and descriptions among them |
| Webhook delivery log | `webhook_deliveries` | Debug an endpoint that did not get an event | 30 days | Not specific to a person; bounded by retention |
| Webhook signing secrets | `webhooks.secret`, encrypted (Active Record Encryption) | Sign payloads | While the webhook exists | Not personal data |
| Idempotency keys and stored responses | `idempotency_keys` | Make retries safe | 24 hours | Deleted |
| Event outbox | `outbox_events` | Publish events reliably | Published rows 7 days | Bounded by retention. Payloads carry ids and the event's own data |
| AI usage ledger | `ai_usages` | Budgets and cost | Indefinitely; **no prompt or answer text** | Rows stay, pointing at the tombstone |
| Embeddings of tasks | `tasks.embedding` | Search | With the task | Follows the task |
| Delivery log of the Notification service: event id, type, channel, **recipient address** | `deliveries` in its own database | Prove something was sent; dedupe | 90 days | **Not reached**; bounded by retention |
| Processed event ids | `processed_events` in its database | Idempotent consumption | 14 days | No personal data |
| Application logs | CloudWatch, 30 days | Operations | 30 days | See "Logs" |
| Backups | Aurora point-in-time recovery (14 days in prod), dumps in S3 (90 days) | Recovery | As stated | **Not reached**; see "After a restore" |

## Erasure: `DELETE /api/v1/me`

The person sends their password (a stolen token alone cannot do it; 5 tries an hour). `AccountErasure` then, in one transaction: ends every sign-in; removes them from projects, organizations and teams; deletes their inbox, preferences, mutes and idempotency keys; unassigns their tasks (and bumps `updated_at` so cached copies go stale); deletes invitations addressed to them and the address from the audit trail; purges the avatar; and turns the user row into a tombstone. It then emits `user.erased` with the id and nothing else.

**The row stays** because tasks, comments, projects and the audit trail point at it with foreign keys, and because rewriting history to hide a person would break the trail more than it protects them. What is left is a name that says `Deleted user`, an address that cannot receive mail, no password and no sign-in. The old address is free to register again.

**Refused, changing nothing**, with a 422 that says what to do:
- `owns_projects`: they own a project that is not archived. A project needs an owner and ownership cannot be handed over (it is fixed for life), so they archive it first.
- `last_organization_owner`: they are the only owner of an organization. Make someone else an owner, or delete the organization.

Also: `409 managed_by_auth_service` when the Auth service owns accounts (JWT mode), and `403 demo_mode` in the public demo. Erasing an already erased user does nothing.

### After a restore

A restore to a time before an erasure brings the person back. Re-apply the erasures made since the backup: the ids are in the `user.erased` log events (kept 30 days in CloudWatch), then

```ruby
ids.each { |id| AccountErasure.call(User.find(id)) }   # bin/rails runner
```

This is manual and bounded by log retention. If restores are routine, keep the list of erased ids somewhere durable.

## Retention, enforced

| Data | Job | Runs |
| --- | --- | --- |
| Expired and idle sessions | `Session.expired.delete_all` | daily 04:00 |
| Idempotency keys (24 h) | `PurgeIdempotencyKeysJob` | daily 04:10 |
| Webhook deliveries (30 d) | `PurgeWebhookDeliveriesJob` | daily 04:20 |
| Published outbox rows (7 d) | `PurgeOutboxJob` | daily 04:30 |
| Concluded invitations (90 d) | `PurgeInvitationsJob` | daily 04:40 |
| Archived tasks and projects (30 d) | `PurgeDiscardedJob` | daily 03:00 |
| Notifications (30 d read, 180 d unread) | `PurgeNotificationsJob` | daily 03:30 |
| Notification service deliveries (90 d), processed events (14 d) | `Consumer#prune_if_due` | hourly, inside the consumer loop |

The webhook delivery log, the invitations and the Notification service's tables had **no** retention until this change: each grew with use and held personal data (task and comment content, addresses of people who may never have signed up). Each is now pruned in batches. The cost was measured: with a million deliveries, a third of them expired, in the worst id order for the query, the purge took 1.3 seconds and needed no new index.

## Where personal data goes beyond the database

- **Logs and metrics.** The log subscriber writes event names and ids (`actor_id`, `organization_id`, `request_id`); the `email`, `password` and token parameters are filtered. Not verified: whether the load balancer's or ingress's access logs record client addresses. Check them before relying on "logs hold no addresses".
- **Email.** Notification mail goes through Amazon SES (SMTP): the recipient's address and the message text, which includes task titles.
- **AI.** With the AI features on, task text and project context are sent to the model provider (Amazon Bedrock in production; an offline fake otherwise). Prompts and answers are not stored; only token counts and cost are.
- **Slack.** Only if `slack_webhook_url` is set: the announcement text the Notification service builds from the event.
- **Webhooks.** A project administrator can point a webhook at any URL that passes validation; that endpoint then receives snapshots of task and comment events. That is the customer's decision and the customer's recipient, outside this system's control.
- **Real-time channels.** Action Cable broadcasts carry the same snapshot as webhooks to the subscribers of the project's channel (members only; `ProjectChannel` rejects anyone else).

## Not built

- **Export of a person's data** (portability, subject access). There is no endpoint; the personal data above is small and an operator can assemble it from the tables listed.
- **Erasure in the Auth service** and **by recipient in the Notification service.** In JWT mode the Auth service holds the credentials and has no delete path; the Notification service stores the address, not a user id, so it cannot match an event for `user.erased` (which carries only the id, on purpose: putting the address on a queue to delete it from a table is the wrong trade). Its log is bounded by the 90-day retention instead.
- **Ownership transfer.** It would make erasing an owner a one-step action.
- **Retention for the audit trail.** It is the largest personal-data holding that has none, and a deliberate one: an append-only trail is worth little if it expires quickly. It is a growth question as well (see [architecture/data-lifecycle.md](architecture/data-lifecycle.md)); the decision is a policy one and belongs to whoever owns compliance.
- **Redaction of free text.** Nothing scans task or comment text for personal data.
- **Encryption of personal data columns.** Data is encrypted at rest by the platform (Aurora storage, S3) and in transit; only webhook secrets are encrypted by the application. A database reader sees names and addresses.
- **Automated re-application of erasures after a restore** (above).
- **Consent records.** The system does not collect consent; it has no analytics or marketing use of the data.
