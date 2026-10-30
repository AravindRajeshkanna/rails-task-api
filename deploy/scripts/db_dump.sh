#!/usr/bin/env bash
# A pg_dump you can trust: custom format, checked before it is kept, optionally encrypted, optionally uploaded to the
# dump bucket (which replicates to another region: deploy/terraform/backup.tf). Run it nightly from cron or a Kamal alias;
# docs/runbooks/backup-and-restore.md has the schedule and the restore rehearsal (db_restore_check.sh).
#
#   DATABASE_URL=postgres://... deploy/scripts/db_dump.sh                       # leaves tmp/dumps/task_api-<UTC time>.dump
#   AGE_RECIPIENT=age1... deploy/scripts/db_dump.sh --upload s3://BUCKET/dumps/ # encrypts, uploads, removes the local copy
#
# Which database: DATABASE_URL, or PGDATABASE with the usual PG* variables.
# Settings: DUMP_DIR (tmp/dumps), AGE_RECIPIENT (an age public key: the file is encrypted before it leaves the machine, and
# only the .age file is kept or uploaded), EXPECT_TABLE (tasks: a dump without it is refused, because it is the wrong database
# or an empty one).
# Prints one line: dump=<file> bytes=<n> sha256=<hex>. A dump that fails to be written or checked is removed; one that was
# checked but could not be encrypted or uploaded is kept, and the exit status says so.
set -euo pipefail
cd "$(dirname "$0")/../.."

upload=""
while [ $# -gt 0 ]; do
  case "$1" in
    --upload) upload="${2:?--upload needs s3://bucket/prefix/}"; shift 2 ;;
    *) echo "usage: $0 [--upload s3://bucket/prefix/]" >&2; exit 2 ;;
  esac
done

database="${DATABASE_URL:-${PGDATABASE:-}}"
[ -n "$database" ] || { echo "Say which database: DATABASE_URL, or PGDATABASE (and PGHOST, PGUSER...)" >&2; exit 2; }
tools=(pg_dump pg_restore)
[ -z "$upload" ] || tools+=(aws)
[ -z "${AGE_RECIPIENT:-}" ] || tools+=(age)
for tool in "${tools[@]}"; do
  command -v "$tool" >/dev/null || { echo "$tool is required but not on the PATH" >&2; exit 2; }
done
if command -v sha256sum >/dev/null; then sha256() { sha256sum "$1" | cut -d' ' -f1; }; else sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }; fi
size() { wc -c < "$1" | tr -d ' '; }

dir="${DUMP_DIR:-tmp/dumps}"
mkdir -p "$dir"
file="$dir/task_api-$(date -u +%Y%m%dT%H%M%SZ).dump"
toc="$dir/.toc.$$"
verified=0
# Until the dump has been read back and checked, a failure leaves nothing that looks like a backup. After that the file stays,
# even if encrypting or uploading it fails, because it is the only copy.
cleanup() { rm -f "$toc"; [ "$verified" = 1 ] || rm -f "$file" "$file.part" "$file.age"; }
trap cleanup EXIT

pg_dump --format=custom --no-owner --dbname="$database" --file="$file.part"
mv "$file.part" "$file"

# A dump that cannot be read back, or does not contain the table everything depends on, is not a backup.
pg_restore --list "$file" > "$toc"
grep -Eq "TABLE public ${EXPECT_TABLE:-tasks} " "$toc" || { echo "the dump has no table ${EXPECT_TABLE:-tasks}: wrong or empty database?" >&2; exit 1; }

final="$file"
if [ -n "${AGE_RECIPIENT:-}" ]; then
  age --recipient "$AGE_RECIPIENT" --output "$file.age" "$file"
  rm -f "$file"
  final="$file.age"
fi
verified=1
digest="$(sha256 "$final")"
echo "$digest  $(basename "$final")" > "$final.sha256"

if [ -n "$upload" ]; then
  aws s3 cp "$final" "$upload" --only-show-errors || { echo "upload failed; the dump is kept at $final" >&2; exit 1; }
  aws s3 cp "$final.sha256" "$upload" --only-show-errors || { echo "upload failed; the dump is kept at $final" >&2; exit 1; }
  echo "dump=${upload%/}/$(basename "$final") bytes=$(size "$final") sha256=$digest"
  rm -f "$final" "$final.sha256"
else
  echo "dump=$final bytes=$(size "$final") sha256=$digest"
fi
