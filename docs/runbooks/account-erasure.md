# Runbook: an erasure that has not been done

**Alerts:** `task-api-<env>-auth-erasure-dlq` (an erasure the Auth service could not do in five attempts), `task-api-<env>-auth-erasure-age` (the oldest erasure has waited more than a day for the Auth service), and `task-api-<env>-notifications-dlq` when what is in it is a `user.erased`.
**Impact:** a person asked to be forgotten and **something of theirs is still held**: their identity in the Auth service (address, password digest, sign-ins), or the Notification service's delivery log. In JWT mode the Task API has already refused their tokens, so they cannot use the service as themselves; what remains is data, not access. The promise is "done", not "done soon", so an alarm here is a promise not kept and is worth a person's attention the same day.

How an erasure travels ([ADR 79](../decisions.md#79-erasing-a-person-across-services-the-outbox-tells-the-auth-and-notification-services-the-tombstone-keeps-the-subject-and-jwt-mode-asks-the-auth-service-for-the-password)):

```
DELETE /me
  -> Task API: one transaction (the tombstone, and user.erased in the outbox) -> relay -> SNS
       -> SQS auth-erasure   -> Auth service: delete the identity
       -> SQS notifications  -> Notification service: delete the delivery-log rows
```

It only moves forward and every step can be repeated: deleting what is already deleted does nothing, so **replaying is always safe**. There is no confirmation back to the Task API, so *done* is read from the queues being empty and the DLQs being empty, not from a table ([ADR 79](../decisions.md) says why).

## 1. Which one is it

| Alarm | It means | Go to |
| --- | --- | --- |
| `auth-erasure-age` | Nothing is taking the Auth service's erasures: the consumer is not running or cannot reach SQS | 2 |
| `auth-erasure-dlq` | The consumer took a message five times and failed each time | 3 |
| `notifications-dlq` | A message of any type failed five times; check whether it is a `user.erased` | 3, for the Notification service |
| neither, and a person says they are still in the system | The event was never sent, or expired before anyone took it | 5 |

## 2. The Auth service is not taking erasures

```sh
kubectl -n task-api get pods -l app.kubernetes.io/name=auth
kubectl -n task-api logs deploy/auth | grep -E 'auth.erasure_(consumer_started|consumer_crashed|failed)'
kubectl -n task-api exec deploy/auth -- wget -qO- localhost:3000/metrics | grep -E '^auth_erasure'     # from inside: /metrics is not served to the outside
```

- `auth_erasure_consumer_last_poll_age_seconds` of `-1` means the consumer is not running in this pod: `AUTH_ERASURE_CONSUMER` is not `"true"`, or it crashed. A crash is logged as `auth.erasure_consumer_crashed` with the error, and ends the pod so that Kubernetes starts it again; a loop of those is the cause to fix.
- A large age with the pod up means it cannot poll: the role (`task-api-<env>-auth` must allow `sqs:ReceiveMessage` on the queue), `AUTH_ERASURE_QUEUE_URL` (it is per environment, in `deploy/gitops/envs/<env>/auth.yaml`), or the network. The consumer logs the AWS error through `Rails.error`.
- The queue keeps a message **14 days**. Past that it is dropped without a trace: if the consumer has been down that long, go to 5.

## 3. A message in a dead-letter queue

```sh
aws sqs receive-message --queue-url "$(terraform -chdir=deploy/terraform output -raw auth_erasure_dlq_url)" --max-number-of-messages 5 --visibility-timeout 0
```

(`--visibility-timeout 0` leaves it where it is.) The body is the CloudEvent: `data.user_id` and `data.auth_subject` and nothing about the person. Then why it failed:

```sh
kubectl -n task-api logs deploy/auth | grep 'auth.erasure_failed'     # error class, message, attempt
```

| Error | Cause | Fix |
| --- | --- | --- |
| `InvalidEvent` ("auth_subject is not a uid", "user_id is not an id", "missing data") | The Task API sent something this service does not understand | A bug in the Task API's `Events::Outbox.record_erasure`; fix it, then replay (5) |
| `ActiveRecord::StatementInvalid`, `ConnectionNotEstablished` | The Auth database was unreachable or refused | Fix the database ([high-latency](high-latency.md)), then redrive (below) |

Once the cause is fixed, **redrive** the DLQ back to the queue:

```sh
aws sqs start-message-move-task --source-arn "$(aws sqs get-queue-attributes --queue-url "$DLQ_URL" --attribute-names QueueArn --query Attributes.QueueArn --output text)"
```

The Notification service's DLQ is the same, with its own logs (`notification.failed`) and its own redrive.

## 4. Check that one person is gone

The Task API keeps the tombstone, with the subject, so the ids are there:

```sh
kubectl -n task-api exec deploy/api -- bin/rails runner 'u = User.find(ID); p [u.erased_at, u.auth_subject]'
kubectl -n task-api exec deploy/auth -- bin/rails runner 'p User.where(uid: "SUBJECT").or(User.where(legacy_id: ID)).count'                      # 0
kubectl -n task-api exec deploy/notifications -- bin/rails runner 'p Delivery.where(recipient_id: ["ID", "SUBJECT"]).count'                     # 0
```

Rows in the Notification service's log from **before `recipient_id` existed** have no id, so they cannot be found by it: they age out under the 90-day retention. That is a known limit, not a failure.

## 5. Send it again

Nothing is lost by sending an erasure twice. For one person, or for everyone erased since a date (a consumer that was down longer than the queue keeps messages, or erasures from before this existed):

```sh
kubectl -n task-api exec deploy/api -- bin/rails erasure:publish USER_IDS=41,42
kubectl -n task-api exec deploy/api -- bin/rails erasure:publish SINCE=2026-11-01
```

It publishes straight to the events topic (not through the outbox, whose row for the same event may already exist), prints how many it sent, and is safe to run twice. A person erased before the tombstone kept its subject (`auth_subject` empty) is still found in the Auth service by the Task API's id, when that account was imported at the cutover; one who was never in the Auth service has nothing there to delete.

## What this does not cover

- The events **in flight** that carry the person's address (a `task.assigned` waiting in the outbox, the queue or a DLQ) are bounded by their retention (7 days after publishing, 4 and 14 days) and are not scrubbed ([data-protection.md](../data-protection.md)).
- Nothing tells the Task API that the other services are done. If that is ever wanted (a record per person and step, filled by confirmation events), it needs the Task API to read a queue; see the ADR.
