#!/usr/bin/env bash
# The load test end to end, against an environment built for the occasion: scratch databases, seeded with
# ~150,000 tasks, the app in production mode on a local port, k6 against it, then everything torn down.
# Exits non-zero when a k6 threshold in loadtest/k6/api.js is breached, so a nightly job can fail on it.
#
#   CI:      the workflow .github/workflows/loadtest.yml runs this with a PostgreSQL service
#   by hand: LOADTEST_CONFIRM=yes RATE=10 DURATION=30s loadtest/ci.sh
#
# DESTRUCTIVE: it drops and recreates the databases task_api_loadtest_ci and task_api_production* and
# creates a task_api database role if there is none. Refuses to run unless CI=true or LOADTEST_CONFIRM=yes.
#
# Settings (environment): RATE (visits per second, 15), DURATION (90s), PORT (3100), and the seeder's
# USERS, PROJECTS, TASKS_PER_PROJECT, WHALE_TASKS (loadtest/README.md). PG* variables say where PostgreSQL is.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${CI:-}" != "true" ] && [ "${LOADTEST_CONFIRM:-}" != "yes" ]; then
  echo "This drops and recreates the databases task_api_loadtest_ci and task_api_production*." >&2
  echo "Run it with LOADTEST_CONFIRM=yes if that is what you want." >&2
  exit 2
fi
for tool in k6 psql createdb dropdb curl ruby; do
  command -v "$tool" >/dev/null || { echo "$tool is required but not on the PATH" >&2; exit 2; }
done

RATE=${RATE:-15}
DURATION=${DURATION:-90s}
export PORT=${PORT:-3100}
SEED_DB=task_api_loadtest_ci
PRODUCTION_DBS="task_api_production task_api_production_cache task_api_production_queue task_api_production_cable"
OUT=tmp/loadtest
mkdir -p "$OUT"
SERVER_PID=""

# shellcheck disable=SC2329 # run by the EXIT trap
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  wait 2>/dev/null
  for db in $SEED_DB $PRODUCTION_DBS; do dropdb --if-exists "$db" >/dev/null 2>&1; done
  return 0
}
trap cleanup EXIT

step() { printf '\n== %s\n' "$*"; }

# What the app in production mode needs to boot against a plain-HTTP scratch database. Rack::Attack is off or the
# test would measure 429s (it is switched on in production by default, see config/initializers/rack_attack.rb).
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(ruby -rsecurerandom -e 'puts SecureRandom.hex(64)')}"
export TASK_API_DATABASE_PASSWORD="${TASK_API_DATABASE_PASSWORD:-loadtest}"
export DB_HOST="${PGHOST:-}"
export FORCE_SSL=false ASSUME_SSL=false RACK_ATTACK_ENABLED=false RAILS_LOG_LEVEL=warn RAILS_MAX_THREADS=5

step "Preparing scratch databases"
for db in $SEED_DB $PRODUCTION_DBS; do dropdb --if-exists "$db"; done
# database.yml connects as task_api in production.
psql -d postgres -v ON_ERROR_STOP=1 -q <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'task_api') THEN
    CREATE ROLE task_api SUPERUSER LOGIN PASSWORD '${TASK_API_DATABASE_PASSWORD}';
  END IF;
END \$\$;
SQL

step "Seeding"
createdb "$SEED_DB"
DATABASE_URL="postgres:///$SEED_DB" RAILS_ENV=development bin/rails db:schema:load loadtest:seed
tasks=$(psql -d "$SEED_DB" -Atc "SELECT count(*) FROM tasks")
createdb -T "$SEED_DB" task_api_production
RAILS_ENV=production bin/rails db:prepare # also creates the cache, queue and cable databases

step "Starting the app (production mode, port $PORT)"
RAILS_ENV=production bin/rails server -b 127.0.0.1 -p "$PORT" >"$OUT/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 90); do
  curl -fsS "http://127.0.0.1:$PORT/up" >/dev/null 2>&1 && break
  kill -0 "$SERVER_PID" 2>/dev/null || { echo "The app exited during boot:" >&2; tail -40 "$OUT/server.log" >&2; exit 1; }
  sleep 1
done
curl -fsS "http://127.0.0.1:$PORT/up" >/dev/null || { echo "The app did not become healthy in 90 s" >&2; tail -40 "$OUT/server.log" >&2; exit 1; }

step "Warming up (code loading, connection pool, caches): not measured"
k6 run --quiet -e BASE_URL="http://127.0.0.1:$PORT" -e RATE=5 -e DURATION=15s -e NO_THRESHOLDS=1 loadtest/k6/api.js >/dev/null

step "Load test: $RATE visits per second for $DURATION against $tasks tasks"
set +e
k6 run -e BASE_URL="http://127.0.0.1:$PORT" -e RATE="$RATE" -e DURATION="$DURATION" --summary-export "$OUT/summary.json" loadtest/k6/api.js 2>&1 | tee "$OUT/k6.log"
status=${PIPESTATUS[0]}
set -e

step "Report"
{
  ruby loadtest/summary.rb "$OUT/summary.json" "$RATE" || true
  printf '\nData: %s tasks. One process of the app (5 threads) and PostgreSQL shared the machine with k6.\n' "$tasks"
} | tee "$OUT/report.md"
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat "$OUT/report.md" >> "$GITHUB_STEP_SUMMARY"

if [ "$status" -ne 0 ]; then
  echo "k6 exited with $status: a threshold was breached or the run failed (see $OUT/k6.log)" >&2
fi
exit "$status"
