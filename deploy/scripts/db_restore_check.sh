#!/usr/bin/env bash
# The restore rehearsal (docs/runbooks/backup-and-restore.md): restores a dump into a scratch database, counts the rows that
# matter, reports how long it took (your real recovery time for a dump of this size), and drops the scratch database. It never
# touches the database the dump came from, and never writes anywhere but the scratch database it creates and removes.
#
#   deploy/scripts/db_restore_check.sh tmp/dumps/task_api-20261103T020000Z.dump
#   AGE_IDENTITY=~/.age/key.txt deploy/scripts/db_restore_check.sh task_api-20261103T020000Z.dump.age
#
# The server to restore into: the usual PG* variables (PGHOST, PGUSER, PGPASSWORD...). It needs the pgvector extension, like the
# original did. Settings: SCRATCH_DB (task_api_restore_check_<pid>), AGE_IDENTITY (the private key, for a .age file).
# Exits non-zero if the dump cannot be restored or has no tasks table.
set -euo pipefail

dump="${1:?usage: $0 <dump or dump.age>}"
[ -f "$dump" ] || { echo "$dump: no such file" >&2; exit 2; }
for tool in pg_restore psql createdb dropdb; do
  command -v "$tool" >/dev/null || { echo "$tool is required but not on the PATH" >&2; exit 2; }
done

scratch="${SCRATCH_DB:-task_api_restore_check_$$}"
work="$(mktemp -d)"
cleanup() { dropdb --if-exists "$scratch" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT

if [[ "$dump" == *.age ]]; then
  : "${AGE_IDENTITY:?a .age file needs AGE_IDENTITY, the path of the private key}"
  command -v age >/dev/null || { echo "age is required but not on the PATH" >&2; exit 2; }
  age --decrypt --identity "$AGE_IDENTITY" --output "$work/dump" "$dump"
  dump="$work/dump"
fi

createdb "$scratch"
started=$SECONDS
pg_restore --no-owner --exit-on-error --dbname="$scratch" "$dump"
elapsed=$((SECONDS - started))

count() { psql --no-psqlrc --tuples-only --no-align --dbname="$scratch" --command="select count(*) from $1"; }
tasks="$(count tasks)" || { echo "the restored database has no tasks table" >&2; exit 1; }
echo "restored in ${elapsed}s: users=$(count users) projects=$(count projects) tasks=$tasks"
extension="$(psql --no-psqlrc --tuples-only --no-align --dbname="$scratch" --command="select count(*) from pg_extension where extname = 'vector'")"
echo "pgvector extension: $([ "$extension" = "1" ] && echo present || echo MISSING)"
echo "compare these numbers with production: bin/rails runner 'puts [User.count, Project.count, Task.count].inspect'"
