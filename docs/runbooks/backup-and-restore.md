# Runbook: database backups and restores

**What is at stake:** all user data lives in PostgreSQL (Aurora on EKS, a Postgres container on the Kamal host). The Solid Queue,
Cache and Cable databases are disposable: losing them drops pending jobs and cached values, not user data.
**Objectives to hold yourself to:** recovery point objective (data you can lose) **5 minutes** on Aurora with point-in-time
recovery; recovery time objective (how long to be back) **under an hour**, which you only know is true if you have rehearsed it
(see [Rehearse](#rehearse)).

## What exists

| | Aurora (EKS) | Kamal host |
| --- | --- | --- |
| Automatic backups | Continuous, with point-in-time recovery inside the retention window: **14 days in prod, 3 elsewhere** (`backup_retention_period` in `deploy/terraform/database.tf`) | **None by default.** You must schedule the dump below |
| Encryption | At rest (`storage_encrypted`); TLS required | Depends on the host's disk; encrypt the backup (below) |
| Final snapshot on delete | Prod only (`skip_final_snapshot = !is_prod`) | n/a |
| Accidental deletion | Prod has `deletion_protection` on | The `postgres_data` Docker volume |
| Cross-region copy | **Off until `backup_copy_region` is set** ([below](#a-copy-in-another-region)): a daily AWS Backup snapshot copied to a vault in another region, built and tested offline, never applied. Point-in-time recovery data stays in the cluster's region; only snapshots can be copied | The dump bucket replicates to another region (same switch); [`db_dump.sh --upload`](#back-up-and-restore-with-pg_dump-kamal-host-and-a-portable-copy-anywhere) puts the dumps there |

Backups protect against deleting or corrupting data, not against everything: a `DELETE` that you notice a day later is recoverable
from point-in-time recovery **only into a new cluster**, from which you copy the rows back. Plan for that, not for an in-place undo.

## Restore on Aurora (point in time)

Restoring never overwrites the live cluster; it creates a new one next to it.

1. Decide the moment: just before the damage (UTC). Note the cluster identifier (`terraform output` or the RDS console).
2. Restore to a new cluster:
   ```sh
   aws rds restore-db-cluster-to-point-in-time \
     --source-db-cluster-identifier task-api-prod \
     --db-cluster-identifier task-api-prod-restore \
     --restore-to-time 2026-11-03T09:41:00Z \
     --db-subnet-group-name <same subnet group> --vpc-security-group-ids <same security group> \
     --serverless-v2-scaling-configuration MinCapacity=0.5,MaxCapacity=4
   aws rds create-db-instance --db-cluster-identifier task-api-prod-restore --db-instance-identifier task-api-prod-restore-1 \
     --db-instance-class db.serverless --engine aurora-postgresql
   ```
3. Connect to the restored cluster from a pod (`kubectl run psql --rm -it --image=postgres:17 -- psql -h <restore endpoint> -U task_api task_api_production`)
   and check the data is what you expect at that moment.
4. Either copy the missing rows back into the live database (`pg_dump --data-only --table=... | psql`), or, if the whole database is
   bad, point the application at the restored cluster and treat it as the new primary: `DB_HOST` is rendered into
   `deploy/gitops/envs/<env>/*.yaml` (api, worker, auth, notifications) from `terraform output database_endpoint` by
   `deploy/scripts/render_gitops.rb`; change it to the restored cluster's endpoint, commit, and Argo rolls the pods. The database
   password is the one in Secrets Manager, which the restored cluster inherits. Then bring Terraform state in line
   (import the new cluster or restore into the Terraform-managed name) before the next `apply`.
5. Delete the restore cluster when you are done; it costs money.

A snapshot restore (`restore-db-cluster-from-snapshot`) works the same way for restoring to a snapshot instead of a moment.

## A copy in another region

Aurora's continuous backup (point-in-time recovery) lives in the cluster's region, so a regional loss takes it with it; only snapshots can be copied out. Setting `backup_copy_region` in the environment's tfvars (`backup.tf`; nothing is created while it is empty) adds:

- **An AWS Backup plan** that snapshots the Aurora cluster daily (`backup_schedule`, 03:00 UTC) into a vault encrypted with a key of its own, and **copies every recovery point to a vault in the other region** (a key of its own there), each kept `backup_retention_days` (35). A failed backup or copy publishes to the alerts topic.
  Point-in-time recovery stays what it was: inside the region, to the second, 14 days. The copy is the answer to "the region is gone", with **a recovery point of up to a day plus the copy time** and a recovery time of one restore.
- **A dump bucket and its copy** (`task-api-<env>-dumps-<account>` and `-dumps-copy-`): private, versioned, expiring after `dump_retention_days` (90). Dumps replicate to the other region, **deletions do not replicate**, and `dump_upload_policy_arn` (an output) is an IAM policy that can add objects and nothing else, so a compromised host cannot read, list or delete the history.

Nothing runs in the other region meanwhile, which is the point: it costs the storage of the snapshots in two vaults plus the transfer, not a second stack. It is **not** a substitute for the warm standby when the objective is minutes ([multi-region](../aws/multi-region.md)); it is the whole answer when an hour of downtime and a day of lost changes are acceptable.

**Restore from the copy** (every command unrun; check each against the CLI reference). In the copy region:

```sh
aws backup list-recovery-points-by-backup-vault --backup-vault-name task-api-prod-backups --region us-west-2      # pick the newest, note its ARN
aws backup get-recovery-point-restore-metadata --backup-vault-name task-api-prod-backups --recovery-point-arn <arn> --region us-west-2
aws backup start-restore-job --recovery-point-arn <arn> --iam-role-arn <task-api-prod-backup role> --region us-west-2 \
  --metadata file://restore-metadata.json     # the metadata above, with a new DBClusterIdentifier, DBSubnetGroupName and VpcSecurityGroupIds for the target region
```

This gives a cluster; to serve from it you also need the rest of the platform in that region, which is what [the multi-region stack](../aws/multi-region.md) builds (or builds in a hurry, a pilot light). Then follow step 4 of the point-in-time restore above.

## Back up and restore with `pg_dump` (Kamal host, and a portable copy anywhere)

Custom-format dumps are compressed, can be restored selectively, and restore in parallel.

**Back up** (nightly, from cron on the host or a Kamal alias): `deploy/scripts/db_dump.sh` writes a custom-format dump, **reads it back** and refuses one that lacks the `tasks` table (the wrong or an empty database), writes a SHA-256 next to it, encrypts it with [age](https://age-encryption.org) if `AGE_RECIPIENT` is set, and, with `--upload`, puts it in the dump bucket (which replicates to another region). A dump that was checked but could not be uploaded is kept and the exit status says so; one that fails its check is removed.

```sh
# the host (Kamal): from the database container, or anywhere that can reach it
DATABASE_URL=postgres://task_api:...@localhost/task_api_production \
AGE_RECIPIENT=age1... deploy/scripts/db_dump.sh --upload s3://task-api-prod-dumps-123456789012/dumps/
# cron:  17 2 * * *   (and keep at least 14 days: the bucket's lifecycle does it)
```

**Restore** into a *new* database first, never straight over production. `deploy/scripts/db_restore_check.sh` does exactly that, reports **how long the restore took** (your real recovery time for this size of data) and the row counts to compare with production, and removes the scratch database:

```sh
aws s3 cp s3://.../dumps/task_api-20261103T020000Z.dump.age .      # from the bucket, or from its copy in the other region
AGE_IDENTITY=~/.age/key.txt deploy/scripts/db_restore_check.sh task_api-20261103T020000Z.dump.age
# restored in 4s: users=500 projects=100 tasks=149000      pgvector extension: present
```

Both scripts ran as written against the 149,000-task database (the dump took about a second and produced 7 MB, the restore took 4 s, and the restored database had every row and the `vector` extension; a damaged dump and a dump of the wrong database both fail and leave nothing behind), and they are exercised by `spec/scripts/db_backup_spec.rb` where the PostgreSQL client is at least as new as the server. **Not run:** `age` and the real `aws s3 cp` (neither is installed here; the upload path was exercised against a stand-in `aws` that copies the file), `kamal accessory exec`, and the Aurora CLI calls above. The scripts need `pg_dump` at least as new as the server, and the restoring server needs pgvector.

The `pgvector/pgvector:pg17` image has pgvector. Restore the
primary database only; Solid Queue, Cache and Cable databases are recreated by `bin/rails db:prepare`.

Active Storage files (avatars, attachments) are not in the database. With `ACTIVE_STORAGE_SERVICE=amazon` they are in S3
(versioning is on in the Terraform, so deleted objects are recoverable); on a Kamal host they are on the `storage` volume, which you
must back up separately (`tar` the volume, or sync it to object storage).

## Rehearse

A backup you have not restored is a hope. Put this in the calendar:

- **Monthly:** restore the latest backup into a scratch database/cluster (`deploy/scripts/db_restore_check.sh` for a dump), compare the row counts with production
  (`bin/rails runner 'puts [User.count, Project.count, Task.count].inspect'`), delete it. Record how long it took: that is your real RTO. **Quarterly:** do it from the copy in the other region.
- **After a major migration:** restore a pre-migration backup and run the migration against it, to learn the time and the lock behavior on real data volume.

## Checklist when something has been deleted

1. Stop the bleeding (disable the job, revert the deploy, revoke the token) before restoring anything.
2. Note the time of the damage and the last known good moment.
3. Restore to a **new** database/cluster as above; inspect; do not touch the live one yet.
4. Copy back only what is needed, in a transaction; keep the audit log (`audit_events`) in mind: restored rows are not new events.
5. Write down what happened, and what would have caught it sooner.
