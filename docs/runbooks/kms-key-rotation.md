# Runbook: encryption keys

For the on-call and for whoever changes a key. What the keys are and what they protect: [docs/aws/kms.md](../aws/kms.md). Every command that touches the application is run inside a pod, which is where the role with access to the key lives:

```sh
kubectl -n task-api exec deploy/api -- bin/rails <task>          # abbreviated below as: rails <task>
```

> **What was rehearsed.** Converting a plaintext column (section 2) was run end to end on a copy of the development database, with the local stand-in key. Everything on AWS, including every Terraform step below, was **not** run: the first time is yours. Read the plan before applying, and do the first rotation in dev.

## What each tool tells you

| Command | Tells you | KMS requests |
| --- | --- | --- |
| `rails kms:status` | For each encrypted attribute, how many values are plaintext, under the Rails key, or under which KMS key id | none |
| `STRICT=1 rails kms:status` | The same, and exits 1 if any value is not under the key new values are made under now | 1 |
| `rails kms:encrypt` | Moves every value that is not under the current key to it (plaintext, Rails-keyed, older KMS key). `PAUSE=0.1` seconds between batches of 500; safe to repeat and to stop | 1 to learn the current key; 1 per moved value that has a key of its own (a webhook secret). Addresses cost none |
| `REWRAP=1 rails kms:encrypt` | Re-encrypts **every** value | as above |
| `rails kms:verify` | Reads every encrypted value with only what is configured now; exits 1 listing those that cannot be read. **The gate before retiring a key or a master** | up to 1 per distinct value, cached |
| `rails kms:generate_wrapped_master` | Prints a new wrapped master (never the plaintext) | 1 |

## 1. Routine: nothing

Each key rotates its material every year by itself. Values wrapped earlier still unwrap (KMS keeps the old material), so **no data is touched and nothing is configured**. Check once that it is on: `aws kms get-key-rotation-status --key-id alias/task-api-prod-data` should say `KeyRotationEnabled: true`. The `key-changes` alarm fires if anyone turns it off.

## 2. Encrypting a column that already holds plaintext

Only for a deployment that has data from before the column was encrypted (`users.email_address` is the case). A new environment has no plaintext and needs none of this: **leave `ENCRYPTION_ALLOW_PLAINTEXT` alone**.

While the window is open the application reads plaintext values, writes ciphertext, and matches both forms in lookups and in the uniqueness check, so sign-in keeps working for people not yet converted.

1. **Check KMS first.** The new version must be ready on KMS before anything is converted: `/readyz` shows `"encryption":"ok"` on every pod. Take a database snapshot.
2. **Open the window** in `deploy/gitops/envs/<env>/api.yaml` and `worker.yaml`, with a date. CI fails the build once the date passes, so it cannot be forgotten:
   ```yaml
   env:
     ENCRYPTION_ALLOW_PLAINTEXT: "true"   # close by 2026-11-15
   ```
   Merge, let Argo CD roll it out. Check: `rails kms:status` now reports `plaintext: N` for `User.email_address`.
3. **Convert.** `rails kms:encrypt` prints each batch of 500. Not measured at scale (the rehearsal converted 6 rows); the arithmetic is that the default pause of 0.1 s per batch is 20 seconds of waiting for 100,000 rows, plus the writes, which depend on the database. Stopping and restarting is safe.
4. **Confirm.** `STRICT=1 rails kms:status` exits 0 and shows only `encrypted`. `rails kms:verify` says every value can be read. A direct look: `SELECT count(*) FROM users WHERE email_address LIKE '%@%'` is 0.
5. **Close the window**: delete the line, merge. Then `kms:verify` again, and sign in.

If something is wrong mid-way: the values already converted stay readable with the window open. Do not close it until `STRICT=1 rails kms:status` passes. There is no way back to plaintext by design; a restore from the step 1 snapshot is the only one, and it loses what happened since.

**Two things the rehearsal found** and the code now handles: Rails' own query extension does not find a plaintext row when the attribute also has `normalizes` (so people not yet converted could not sign in during the window; `config/initializers/encryption_transition.rb` fixes it while the flag is on and has its own spec), and an address typed with different case or spaces needed the same repair. Re-check that initializer on every Rails upgrade.

## 3. Moving webhook secrets off the credentials key

Secrets written before KMS were encrypted with the key in `config/credentials.yml.enc`; they still read (a fallback), and `rails kms:encrypt` moves them. After it:

1. `STRICT=1 rails kms:status` exits 0 (no `rails_key` left) and `rails kms:verify` passes.
2. Only then may `active_record_encryption.primary_key` be removed from the credentials, which makes the fallback disappear by itself. **Do not do this in `config/credentials.yml.enc` while Kamal or docker compose deployments use it**: they run on the credentials source and need it. Give the KMS environments their own file (`bin/rails credentials:edit --environment production`).
3. What this buys: the Rails master key (in Secrets Manager and in every pod's environment) no longer decrypts webhook secrets. A database dump plus the master key is no longer enough.

## 4. Emergency rotation of the data key

When to: the key's policy or an IAM grant was changed by someone who should not have; a role that could use the key was compromised and the data keys it could unwrap are therefore known; an auditor asks. **Not** for routine rotation (section 1). This makes new values use a new key and moves old values to it. What the compromised role already read stays read: rotating the key does not un-leak a data key, only a new value is safe. The webhook secrets themselves need replacing too (recreate the webhook; there is no rotation with an overlap yet, [T18](../threat-model.md)).

1. **Add a generation.** In the environment's Terraform variables (`TF_VARS_JSON` on the GitHub Environment) set `data_key_generations` to `[1, 2]`, for **both** regions of a pair. Run **Provision AWS** with `plan`. The plan must show: key `["2"]` created (and its replica, in a pair), the stable alias updated in place to the new key, `aws_kms_ciphertext.deterministic_master[0]` **replaced** (the same master wrapped under the new key, so retiring the old key never takes the only copy), the grants widened to both keys, **and nothing destroyed**. Then `apply`.
2. **Give the pods the re-wrapped master.** `terraform output -raw kms_wrapped_deterministic_key` (the apply summary has the outputs), then:
   ```sh
   aws secretsmanager get-secret-value --secret-id task-api/prod/api --query SecretString --output text \
     | jq --arg wrapped "<the value>" '.kms_wrapped_deterministic_key = $wrapped' > /tmp/api.json
   aws secretsmanager put-secret-value --secret-id task-api/prod/api --secret-string file:///tmp/api.json && rm -f /tmp/api.json
   kubectl -n task-api rollout restart deploy/api deploy/worker      # the secret is read at start; External Secrets refreshes hourly
   ```
   Until the restart, pods keep working on the old wrapped master under key 1, which is still there.
3. **New values are already under key 2** (the alias moved in step 1). Move the old ones: `rails kms:encrypt` (add `PAUSE=0.5` on a busy database).
4. **Prove nothing refers to key 1.** `STRICT=1 rails kms:status` exits 0; `rails kms:verify` passes. Also read CloudTrail for a day: no `Decrypt` should name key 1 (`resources[].ARN`) except from this procedure.
5. **Retire key 1.** Remove `1` from `data_key_generations` and apply. Its deletion is scheduled with a waiting period (30 days in prod, 7 elsewhere) and can be cancelled in that time; the `key-changes` alarm fires, expectedly. After the period it is gone and **anything still under it is unreadable for good**.

If it goes wrong before step 5, the old key still works: set the list back to `[1]` only if no value is under key 2 (otherwise keep both), and investigate.

## 5. Rotating the master that email addresses derive their keys from

When to: the master may have been seen. It exists in plaintext in **Terraform's state** and, unwrapped, in each pod's memory. Whoever could read the state bucket and also use the data key can derive the addresses' keys. (Routine rotation of the KMS key does not change the master; section 4 only re-wraps it.)

1. **Keep the old wrapped master**, newest first, before anything changes: `aws secretsmanager get-secret-value --secret-id task-api/prod/api --query SecretString --output text | jq -r .kms_wrapped_deterministic_key`.
2. **Make a new one.** Run **Provision AWS** with `replace` = `random_bytes.deterministic_master[0]` and look at the plan first: it replaces the random bytes and the wrapped copy, nothing else. Apply; put the new `kms_wrapped_deterministic_key` into Secrets Manager as in section 4 step 2.
3. **Let the pods read both.** Set `KMS_PREVIOUS_WRAPPED_DETERMINISTIC_KEYS` to the old wrapped master in `api.yaml` and `worker.yaml` (the same `# close by` rule is *not* enforced for this one: remove it in step 5). Roll out. While it is set the application writes with the new master, reads with either, and finds addresses stored under either.
4. **Move the addresses.** `REWRAP=1 rails kms:encrypt`. (`kms:status` cannot say which master a deterministic value is under: the stored bytes do not record it. This is why `kms:verify` is the gate.)
5. **Prove it, then let the old one go.** Run the check in a pod **without** the old master: `kubectl -n task-api exec deploy/api -- env -u KMS_PREVIOUS_WRAPPED_DETERMINISTIC_KEYS bin/rails kms:verify`. If it passes, remove the variable from both files and merge.

Rehearsed by a spec on a throwaway table (read through the previous master, move with `encrypt`, read with the previous gone), not on AWS. One non-obvious thing found by it: Rails keeps writing a deterministic attribute with its **oldest** scheme when it has a previous one, so without `fixed: false` the rotation would read old values and never move them; the model macro sets it while previous masters are configured.

## 6. When KMS fails

`taskapi_kms_requests_total{outcome!="ok"}` and the `kms.failed` log lines name the reason.

| Outcome | Meaning | Look at |
| --- | --- | --- |
| `access_denied` | The role may not, or the key policy refuses | The pod's role (`kubectl -n task-api describe sa api` and the Pod Identity association); the key policy (`aws kms get-key-policy`); CloudTrail for a `PutKeyPolicy`; whether the request carried `app = task-api` (a code change to the context would be refused by the key policy's guard) |
| `key_unusable` | Disabled, pending deletion, or the alias points at nothing | `aws kms describe-key --key-id alias/task-api-prod-data` (`KeyState`); `aws kms list-aliases`; CloudTrail for `DisableKey`, `ScheduleKeyDeletion`, `DeleteAlias`. A key pending deletion can be restored with `aws kms cancel-key-deletion` then `enable-key` |
| `throttled` | The request quota | Service Quotas for KMS cryptographic operations. The cache should make this unreachable; if it is reached, see `TaskApiKmsUnusualVolume` first |
| `network` | Cannot reach KMS | The VPC endpoint (`kms` in `network.tf`), the NetworkPolicy (`allowInternetHTTPS`), DNS |
| `credentials` | The pod has no AWS identity | Pod Identity association; the ServiceAccount name must equal the release name |
| `service` | KMS itself | The AWS Health dashboard |
| `invalid_ciphertext` | A wrapped key does not unwrap under its key and context | Not an outage: a value copied from another attribute, or damaged. `rails kms:verify` lists them |

What users see meanwhile is in [kms.md](../aws/kms.md#when-kms-is-unavailable). **Do not** restart pods to "fix" it: a restarted pod must unwrap the master again and, if KMS is the problem, stays unready, while the pods you have still serve.

## 7. Reading a value by hand

Support needs a webhook's secret, or an address from a snapshot. Do it through the application, so that the role, the context and the audit trail are the ordinary ones:

```sh
kubectl -n task-api exec -it deploy/api -- bin/rails console
> Webhook.find(123).secret
```

Direct `aws kms decrypt` works only with the encryption context (`--encryption-context app=task-api,table=webhooks,attribute=secret`) and a principal the data key's grants allow; the key policy refuses a request without the context, even from an administrator. Your own identity then appears in CloudTrail, which is the point.

## 8. A role, the state or a key is suspected compromised

| What | Does | Then |
| --- | --- | --- |
| The api or worker role (a pod, a stolen session) | Could unwrap any data key it was shown and call `GenerateDataKey` | Revoke the role's sessions (IAM *Revoke active sessions*); read CloudTrail `Decrypt` by that identity for the window; section 4 if values must be treated as known; recreate the webhooks whose secrets it could read |
| Terraform's state bucket | Holds the master in plaintext | Section 5, and review who can read the bucket |
| The key policy was changed | Anyone named could use or administer the key | `aws kms get-key-policy` against `kms.tf`; `terraform apply` restores it; section 4 |
| The Rails master key | No longer decrypts webhook secrets once section 3 is done; before that, it does | Section 3 first, then rotate the credentials |

## 9. Restores, a standby, and tearing down

- **A database restore** (snapshot, point in time, `pg_dump`) brings back ciphertext. It is readable only by a principal that can use the data key, in a region where the key (or its replica) exists. A restore into **another account** is unreadable on purpose; the restore drill counts rows and does not read encrypted columns.
- **A standby** reads the same database through the **replica** of the data key (multi-Region), configured with the same alias. Offline tests show the wiring; the first failover drill ([failover-drill.md](failover-drill.md)) should include reading an address and a webhook secret in the standby region.
- **Tearing down** an environment schedules its keys for deletion. After the waiting period every encrypted value in any surviving backup is **permanently unreadable**. If a backup must stay usable, cancel the deletion first.
