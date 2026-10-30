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
| Cross-region copy | Not configured; the cheap first step of [the multi-region plan](../aws/multi-region.md#before-building-it) | Copy the dumps off the host |

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

## Back up and restore with `pg_dump` (Kamal host, and a portable copy anywhere)

Custom-format dumps are compressed, can be restored selectively, and restore in parallel. This exact procedure was run against a
149,000-task database: the dump took about a second and produced 7 MB, the restore about two seconds, and the restored database had
every row, the `vector` extension and all validated CHECK constraints.

**Back up** (nightly, from cron on the host or a Kamal alias; keep at least 14 days and copy them off the machine):

```sh
kamal accessory exec postgres \
  "pg_dump --format=custom --no-owner --username task_api task_api_production" > "task_api-$(date -u +%Y%m%dT%H%M%SZ).dump"
# encrypt before it leaves the host, e.g.:  age -r <public key> -o ...dump.age ...dump
```

**Restore** into a *new* database first, never straight over production:

```sh
createdb task_api_restore_check
pg_restore --no-owner --exit-on-error --dbname=task_api_restore_check task_api-20261103T020000Z.dump
psql task_api_restore_check -c "select count(*) from tasks; select count(*) from users;"
```

The `pg_dump` and `pg_restore` commands were run as written. The Aurora CLI calls and the `kamal accessory exec` wrapper were
**not** run (there is no AWS account or Kamal host behind this repository yet): check them against your CLI versions, and note that
`kamal accessory exec` starts a fresh container unless you pass `--reuse` to run in the existing one.

pgvector must be installed on the restoring server (the `pgvector/pgvector:pg17` image has it). Restore the
primary database only; Solid Queue, Cache and Cable databases are recreated by `bin/rails db:prepare`.

Active Storage files (avatars, attachments) are not in the database. With `ACTIVE_STORAGE_SERVICE=amazon` they are in S3
(versioning is on in the Terraform, so deleted objects are recoverable); on a Kamal host they are on the `storage` volume, which you
must back up separately (`tar` the volume, or sync it to object storage).

## Rehearse

A backup you have not restored is a hope. Put this in the calendar:

- **Monthly:** restore the latest backup into a scratch database/cluster, run `bin/rails runner 'puts [User.count, Project.count, Task.count].inspect'`
  against it, compare with production, delete it. Record how long it took: that is your real RTO.
- **After a major migration:** restore a pre-migration backup and run the migration against it, to learn the time and the lock behavior on real data volume.

## Checklist when something has been deleted

1. Stop the bleeding (disable the job, revert the deploy, revoke the token) before restoring anything.
2. Note the time of the damage and the last known good moment.
3. Restore to a **new** database/cluster as above; inspect; do not touch the live one yet.
4. Copy back only what is needed, in a transaction; keep the audit log (`audit_events`) in mind: restored rows are not new events.
5. Write down what happened, and what would have caught it sooner.
