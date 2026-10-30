# Runbook: migrating the database without downtime

**When:** every change to `db/migrate`. **Why it matters:** during a rollout the old and the new code run side by side. On EKS the
migration Job runs *first* (Argo sync-wave -1) while the old pods are still serving traffic; with Kamal the same is true for the
seconds both containers are up. So a migration must work with the **old** code, and the new code must work with the schema
**before** the migration if the rollout is interrupted.

[`strong_migrations`](https://github.com/ankane/strong_migrations) (`config/initializers/strong_migrations.rb`) refuses the
unsafe operations in development and CI and prints the safe alternative. This page is the rules behind it. Migrations up to
`20261029150000` predate the check.

## The rule: expand, deploy, contract

Never rename, retype or drop in one step. Split it across releases:

1. **Expand:** add the new thing, keep the old. Deploy.
2. **Migrate:** start writing both, backfill existing rows (in batches, outside the schema migration). Deploy.
3. **Contract:** stop using the old thing in code. Deploy. Only then drop it, in a later release.

## Recipes

| You want to | Do not | Do |
| --- | --- | --- |
| Add a column | add it `NOT NULL` without a default on a big table | add it nullable (a constant default is fine on PostgreSQL 11+), backfill, then add the constraint as below |
| Add an index | `add_index` on a live table | `disable_ddl_transaction!` and `add_index ..., algorithm: :concurrently` (see `AddActiveTasksListingIndex`) |
| Add a foreign key | `add_foreign_key` (validates under a heavy lock) | `add_foreign_key ..., validate: false`, then `validate_foreign_key` in the **next** migration (see the organizations migrations) |
| Add a CHECK or NOT NULL constraint | `add_check_constraint` directly | `add_check_constraint ..., validate: false`, then `validate_check_constraint` in the next migration (see `AddCheckConstraintsNotValid`) |
| Add a reference | `add_reference` with a default index | `add_reference ..., index: { algorithm: :concurrently }` and a non-validated foreign key, in a `disable_ddl_transaction!` migration |
| Rename a column or table | `rename_column` | add the new column, copy, switch the code over, drop the old (expand / contract) |
| Change a column's type | `change_column` | add a new column of the new type and migrate as above |
| Remove a column | `remove_column` while code still reads it | first `self.ignored_columns += ["old"]` in the model, deploy, then drop |
| Add a stored generated column (e.g. `tasks.search_vector`) | `add_column ... stored: true` on a table you cannot afford to lock | it **rewrites the table under an ACCESS EXCLUSIVE lock**, so it is the exception to "online": measure it first (2.7 s for 149,000 tasks, ~18 s per million rows, more with embeddings), use `safety_assured` with that number in a comment, and run it in a quiet period. For a table where that is too long, expand instead: add a nullable plain column, keep it current with a trigger (`CREATE TRIGGER ... tsvector_update_trigger(...)`, which needs `schema_format = :sql` to survive `db:schema:load`), backfill in batches, index concurrently |
| Backfill data | `update_all` over the whole table inside the migration | a job or rake task that works in batches (`in_batches`), run after the deploy |

Each migration should do **one** thing, so it can be retried and reasoned about. Index and validation migrations are separate for
this reason.

## Locks and timeouts

`strong_migrations` sets `lock_timeout` to 10 s and `statement_timeout` to 1 h. A migration that cannot get its lock in 10 seconds
fails instead of queueing behind a long transaction and blocking every request behind it. If it fails on the lock: find the
long transaction (`SELECT pid, state, query_start, query FROM pg_stat_activity WHERE state <> 'idle' ORDER BY query_start;`), let
it finish or end it, and re-run the Job. Migrations are idempotent per version, so a retry is safe.

## When the guard is wrong

If you have checked that an operation is safe (an empty table, a table only this feature uses), wrap it:

```ruby
safety_assured { remove_column :feature_flags, :legacy }
```

and say why in a comment. A reviewer should be able to see what you checked.

## Rolling back

Prefer rolling the **code** back and leaving an expand-only migration in place: that is exactly why migrations are additive. On EKS,
revert the image tag commit (Argo Rollouts aborts a canary automatically on a failed analysis). Do not run `db:rollback` in
production unless the migration is a pure `change` that you have read and the new code is already gone. Dropping what was expanded
is the contract step of a later release.

## Before you merge a migration

- [ ] It passes `strong_migrations` without `safety_assured`, or the reason is in a comment.
- [ ] The old code works against the new schema (try it: run the previous commit's specs against the migrated database).
- [ ] Big tables: have you estimated the lock and the duration? Look at `EXPLAIN` of any backfill.
- [ ] `db/schema.rb` is committed and CI's `db:test:prepare` loads it.
