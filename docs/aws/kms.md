# Encryption keys: AWS KMS and the encrypted columns

What is encrypted by the application, who holds the keys, what each key is allowed to do, and how to run it. The reasons for the choices are in [ADR 69](../decisions.md) (the library and what is encrypted), [ADR 70](../decisions.md) (the keys and who may use them) and [ADR 71](../decisions.md) (the one-click provisioning that creates them). The procedures (rotation, converting a column, an outage) are in the [runbook](../runbooks/kms-key-rotation.md).

> **Nothing here has run against AWS.** The Ruby side was run against the real AWS SDK talking to a KMS-compatible stand-in (moto), and the Terraform is tested offline against mocked providers. What AWS itself accepts or refuses is not verified; see "Not verified" at the end.

## What is encrypted

| Data | Encrypted by the application | Why, or why not |
| --- | --- | --- |
| `users.email_address` | **Yes**, deterministic | What people sign in with, so it has to be findable by equality. The longest-lived copy of an address |
| `webhooks.secret` | **Yes**, a data key of its own per value | Signs payloads. Was encrypted with the Rails credentials key; now KMS protects the key |
| `users.name` | No | Shown in every list; a ciphertext cannot be sorted or searched |
| Task titles, descriptions, comments | No | Visible to every project member, searched with full text and embedded for the AI features. Encrypting them would remove both |
| `organization_invitations.email_address` | No | The same address sits in the audit trail as plaintext (below), so encrypting this column would protect nothing |
| Phone numbers, private notes, project credentials, task attachments' metadata | n/a | The roadmap this work followed lists them; **this schema has none of them** |

Where an address is still in plaintext after this change, and why ([data-protection.md](../data-protection.md) has the retention of each):

| Copy | Kept | Why it stays |
| --- | --- | --- |
| `audit_events.audit_changes` (invitation addresses) | Indefinitely | Append-only history; whether to encrypt or hash it is a policy decision, not a technical one |
| `outbox_events.payload` (`task.assigned` carries the assignee's address) | 7 days after publishing | The consumer needs the address and must not call back |
| The Notification service's `deliveries` | 90 days | Its own database and service |
| The queue and its dead-letter queue | 14 days at most | Same payload |
| Application and load balancer logs | 30 days | Parameters named `email` are filtered; free text is not |

So encrypting `users.email_address` removes the **permanent** plaintext copy from the main database and its backups. It does not make an address unreadable to someone who can read every table.

## How it works

**Envelope encryption.** KMS never sees the data and the application never holds the master key. For a value that has its own key (`webhooks.secret`):

1. Writing: the application asks KMS for a fresh 256-bit data key (`GenerateDataKey`). KMS returns it twice, in plaintext and wrapped by the KMS key. Rails encrypts the value with the plaintext key (AES-256-GCM) and stores, in the value's own header, the **wrapped** key and the id of the KMS key that wrapped it. The plaintext key is kept in memory for five minutes and then forgotten.
2. Reading: the header gives the wrapped key and the key id; the application asks KMS to unwrap it (`Decrypt`, naming that key id) and decrypts the value. Unwrapped keys are cached (5 minutes, 1,000 keys, least recently used out first), so reading the same webhook again, or saving a record whose secret was already read, asks nothing.

**Deterministic columns** cannot work that way: the same address must always give the same ciphertext, or `where(email_address: ...)` and the unique index stop working. So a 32-byte master secret is made once, **wrapped by KMS**, and the wrapped form is configuration. Each process unwraps it once (first use) and derives a separate key per column from it (HKDF, with `table.column` as the context). After that, **signing in, looking up and listing make no KMS request at all**: measured, 20,000 encryptions at 20 µs each and none to KMS.

**The encryption context.** Every request carries `app = task-api`, and the data key's requests also name `table` and `attribute`. KMS records the context in CloudTrail and requires the same context to unwrap, so a wrapped key copied from one attribute to another does not unwrap, and a policy can require it (the data key's does, below). Rails does not tell a key provider which record a value belongs to (and a new record has no id yet), so **the context cannot name the row**, only the application, table and attribute.

## Keys

Three customer-managed keys per environment, one per purpose, so that what may use one cannot use another. Each rotates its key material every year (AWS does it; wrapped keys made earlier still unwrap, so no data is touched).

| Key | Alias | Protects | Used by |
| --- | --- | --- | --- |
| **data** | `alias/task-api-<env>-data` (and `-g<N>` per generation) | The data keys of encrypted columns, and the wrapped master | the **api** (`GenerateDataKey`, `Decrypt`) and the **worker** (`Decrypt` only) |
| **storage** | `alias/task-api-<env>[-dr]-storage` | The Active Storage bucket (SSE-KMS, with an S3 bucket key so S3 does not call KMS per object) | S3, on behalf of the api and worker (`kms:ViaService` = S3) |
| **secrets** | `alias/task-api-<env>-secrets` | Secrets Manager's secrets | External Secrets |

The **data key is a multi-Region key** (it cannot be made one later, so it always is). The standby region reads the same database, so it must be able to unwrap what the primary wrapped: the primary's stack makes a replica of each generation in the standby's region (the same way it makes the secrets' replicas) and the standby finds it by alias. The alias has the same name in both regions, so the application there is configured exactly like this one. The storage key is not replicated: S3 replication re-encrypts each object under the other region's key. A standby's secret replicas stay under that region's AWS-managed key.

**Key policy** of the data key: the account administers it (so access is granted in IAM, where it is visible), plus a guard no IAM policy can lift: any `Decrypt`, `GenerateDataKey` or `Encrypt` **without** `app = task-api` in its context is refused, for everyone. A console session or a stolen credential that does not say who it is calling for gets nothing, and every permitted request is attributable in CloudTrail.

## Permissions

| Principal | May | Not |
| --- | --- | --- |
| api pods | `kms:GenerateDataKey`, `kms:Decrypt` on the data key(s), with the context; the storage key through S3 | `Encrypt`, `DescribeKey`: the application calls neither |
| worker pods | `kms:Decrypt` on the data key(s), with the context; the storage key through S3 | Making keys: it only reads encrypted columns (it delivers webhooks) |
| auth, ai, notifications | nothing in KMS | They read none of these columns |
| External Secrets | `kms:Decrypt` on the secrets key | The data key |
| The Terraform role | administers the keys | Using the data key without the context (the policy refuses it too) |

The permissions are on **key ARNs**, not on an alias: an alias in an IAM `Resource` does not grant access to the key it points at. The application uses the alias; Terraform lists the keys.

This departs from the generic list in the roadmap this followed (`Encrypt`, `Decrypt`, `GenerateDataKey`, `DescribeKey` for every workload): `Encrypt` is not needed once the data key comes from `GenerateDataKey`, `DescribeKey` is never called, and a worker that only reads should not be able to make keys.

## Configuring the application

`config/initializers/kms_encryption.rb` chooses where keys come from:

| Set | Source | For |
| --- | --- | --- |
| `KMS_KEY_ID=alias/task-api-prod-data` and `KMS_WRAPPED_DETERMINISTIC_KEY` | **AWS KMS** | EKS: the Helm values and the GitOps templates set both |
| `ENCRYPTION_KEY_SOURCE=credentials` | Rails' own keys from `config/credentials.yml.enc` | What is not on AWS: Kamal, docker compose (both set it) |
| nothing, in development | an in-memory stand-in with a **public** key | Development, with no AWS account |
| anything in tests | the same stand-in, whatever the shell exports | Tests never reach AWS |
| nothing, in production | **no source: it refuses**, `/readyz` fails | A deployment that forgot must not guess, and must never encrypt with a public key (`ENCRYPTION_KEY_SOURCE=local` is refused in production) |

Nothing calls KMS while the application boots, so building the image or running a migration needs no AWS access. The first use does, and **`/readyz` waits for it** (the `encryption` check): a pod whose KMS settings are wrong stays unready and a rollout stalls instead of serving errors. Once a pod has its keys it keeps them, so a later KMS outage does not take a serving pod out of rotation.

Other settings: `KMS_ENDPOINT` (a VPC endpoint, or a KMS-compatible server for tests), `ENCRYPTION_ALLOW_PLAINTEXT=true` (only while converting a column; the runbook), `KMS_PREVIOUS_WRAPPED_DETERMINISTIC_KEYS` (only while rotating the master).

In a model: `encrypts_with_kms :secret` or `encrypts_with_kms :email_address, deterministic: true`. A spec fails if an encrypted attribute is added any other way.

## When KMS is unavailable

| What | What happens |
| --- | --- |
| Reading or looking up an address, signing in | Nothing: the key is in memory |
| Reading a webhook secret whose key is cached | Nothing |
| Delivering a webhook whose key is not cached | The job waits and retries (8 attempts, polynomial back-off), without calling the receiver |
| Creating a webhook | `503 encryption_unavailable` with `Retry-After: 5`; nothing is created |
| A pod that is starting | Stays unready until it can unwrap the master; running pods are unaffected |
| `AccessDenied`, key disabled, key deleted | The same as unavailable to the client, with the reason in the logs and in `taskapi_kms_requests_total{outcome=...}` |

An outage is never reported as corrupt data: `KmsEncryption::Unavailable` is a different class from Rails' `Decryption` error.

## Watching it

| Signal | Where | Fires when |
| --- | --- | --- |
| `taskapi_kms_requests_total{operation,outcome}`, `taskapi_kms_request_duration_seconds` | the API's `/metrics` | always; only requests that reach KMS are counted |
| `TaskApiKmsFailing` (ticket) | Prometheus, [rules](../../deploy/observability/prometheus/task-api-rules.yaml) | any non-`ok` outcome for 10 minutes |
| `TaskApiKmsUnusualVolume` (ticket) | Prometheus | over 2 requests a second for 15 minutes. **Chosen, not measured** |
| CloudTrail trail of KMS events only | S3 (kept 365 days) and CloudWatch Logs (90 days) | [`kms_audit.tf`](../../deploy/terraform/kms_audit.tf); off with `enable_kms_audit = false` where the account already has a trail |
| `<name>-kms-decrypt-volume` | CloudWatch alarm | over 2,000 of the application's Decrypts in five minutes. **Chosen, not measured**: read the `TaskApi/KMS DecryptRequests` metric for a few weeks and set `kms_decrypt_alarm_threshold` to a multiple of the busiest ordinary window |
| `<name>-kms-access-denied` | CloudWatch alarm | any refusal |
| `<name>-kms-key-changes` | CloudWatch alarm | a key or alias disabled, scheduled for deletion, re-pointed, or its policy or rotation changed. Expected during a planned rotation |

"Who decrypted what" is a CloudTrail query: every request carries `requestParameters.encryptionContext.app`, `table` and `attribute`, and `userIdentity` names the pod's role.

## Cost

The arithmetic, with the one number I could not verify:

- **Requests** (the part that depends on this application): one `GenerateDataKey` per webhook secret written; one `Decrypt` per webhook per pod per five minutes at most; one `Decrypt` per pod start; **none** for addresses. A pod that serves only sign-ins and lookups makes one request in its life. Compare the library this replaced the idea of: reading 101 rows made 101 requests.
- **Keys**: three per environment, each billed monthly, plus a replica of the data key (and of each generation) in the standby's region.
- **Prices** change and were not looked up for this document: use the [KMS pricing page](https://aws.amazon.com/kms/pricing/). Multiply the request counts above by the per-request price; the per-key price by the key count.
- The CloudTrail trail records KMS events only, which keeps its cost to those events. A second trail that records management events for the whole account is billed as a second copy.

## Where this differs from the roadmap it followed

| The roadmap says | What was done, and why |
| --- | --- |
| `gem "active_kms"` and `ActiveKms::AwsKeyProvider` | A small provider of our own (`gems/kms_encryption`). Measured on Rails 8.1.4: the gem makes one `Encrypt` and one `Decrypt` per create, four `Decrypt`s to save a record whose attribute was read, one per row read; it sends no encryption context; it turns every KMS error into "no key", which Rails reports as a decryption error. ADR 69 |
| `encrypts :email, deterministic: true` with the provider configured globally | **That would not use KMS.** In Rails 8.1 a deterministic attribute never consults the configured provider; it reads `deterministic_key` from the credentials. Hence the wrapped master |
| "Use encryption context: `{ model, id }`" | The row cannot be named: Rails gives a provider no record, and a new record has no id. The context names the application, table and attribute |
| "Separate permissions: Encrypt for some, Decrypt for others" | Done at the level that is possible: the api writes and reads, the worker only reads, nothing else has access. Not possible *within* a process |
| Key ARN or alias ARN in the policy | Key ARNs: an alias does not grant access. The application uses the alias; Terraform lists the keys |
| `kms:Encrypt`, `kms:DescribeKey` | Neither is called; neither is granted |
| "Different keys per environment" | Each environment has its own state and so its own keys; the alias carries the environment |
| "Enable CloudTrail logging on the key" | A KMS-only trail with alarms |
| "Rotation: create a new key, re-encrypt, update the alias" | `data_key_generations` in Terraform; the alias moves in the same apply; the old key keeps decrypting until `bin/rails kms:verify` and `kms:status` say nothing refers to it |
| Phase 7: files, secrets, job arguments, multi-tenant keys, blind indexes | Files: built (SSE-KMS). Secrets: built. Job arguments: **nothing sensitive is passed**, now a spec. Per-organization keys and blind indexes: not built, with reasons in ADR 70 |

## Not verified

- **Nothing was applied to AWS.** Terraform is validated and tested offline against mocked providers; IAM, key policies, `aws_kms_replica_key`, S3 replication with KMS, CloudTrail advanced event selectors and the metric-filter patterns are as AWS documents them, not as AWS accepted them.
- The Ruby code was run against the real AWS SDK and a KMS-compatible server (moto), which does **not** enforce disabled keys or key mismatch the way AWS does; those error paths are covered by stubbed responses of the shape AWS documents.
- Real KMS latency, the wrapped key's size (moto's is 96 bytes; AWS's is larger), throttling behaviour and the quota were not measured.
- The CloudTrail metric-filter patterns (`requestParameters.encryptionContext.app`) assume what a KMS record contains; check one real record.
- The alarm thresholds (2,000 Decrypts per five minutes; 2 requests a second) are chosen, not observed.
- The conversion of an existing column was rehearsed on a copy of the development database (6 users, local stand-in), not on a production-sized table.
