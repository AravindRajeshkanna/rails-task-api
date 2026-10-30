# Load testing

[k6](https://k6.io) scripts and a data generator. The results of the last run, and what they do and do
not tell you, are in [docs/performance.md](../docs/performance.md).

## What it does

`k6/api.js` simulates people visiting the API at a fixed **arrival rate** (the open model: visitors turn up
whether or not the server keeps up, which is how real traffic behaves). A visit is:

- **85% browsing:** list projects, list a project's tasks (default order, by cursor, filtered and sorted, substring
  and full-text search), search across projects, open a task, load analytics, load the activity feed.
- **15% writing:** create a task, update it, comment on it.
- **20% of visits go to one "whale" project** holding 50,000 tasks, because the queries that are fine at a
  thousand rows and slow at fifty thousand are the ones worth finding.

Thresholds fail the run (exit code 99) if reads go over p95 400 ms / p99 1 s, writes over p95 600 ms, a few named
endpoints go over their own limits (the 50,000-task list, analytics, search), more than 1% of requests fail, or more than 2% of
visitors are turned away (`dropped_iterations`: the server could not keep up).

## In CI: nightly

`.github/workflows/loadtest.yml` runs the whole thing every night (02:17 UTC), on demand (*Actions → Load test → Run workflow*, with a rate and a
duration), and on pull requests that touch the load test itself (a short run, to prove the harness works). It uses `loadtest/ci.sh`, which builds an
ephemeral production-mode environment on the runner (a PostgreSQL service, the ~150,000-task data set, the app on localhost), warms the process,
runs k6, writes a latency table to the job summary, uploads `summary.json`, the k6 log and the server log as the `loadtest-results` artifact, and
exits non-zero if any threshold above is breached. A failed **nightly** run opens (or comments on) an issue titled "Nightly load test is failing".

The same script runs on your machine. It drops and recreates the databases `task_api_loadtest_ci` and `task_api_production*` (and creates a
`task_api` database role if there is none), so it insists on `LOADTEST_CONFIRM=yes`:

```sh
LOADTEST_CONFIRM=yes RATE=10 DURATION=30s loadtest/ci.sh
LOADTEST_CONFIRM=yes USERS=100 PROJECTS=20 TASKS_PER_PROJECT=300 WHALE_TASKS=5000 RATE=5 DURATION=20s loadtest/ci.sh   # a quick smoke run
```

**Reading a CI result.** A runner shares two or more cores between k6, the app and PostgreSQL, so absolute numbers are not comparable with the table in
[performance.md](../docs/performance.md) (measured on a laptop) and vary run to run. What the nightly run guards is the *thresholds*, set about ten
times above normal, so that a breach means something changed (a query lost its index, an N+1 appeared), not that the runner had a bad night. The
workflow therefore re-runs a breach once on a fresh environment, and only two in a row fail the job. (Observed: the same code, one night with a 7 ms median for
the activity feed and another, on a slower runner, with 75 ms, a tenfold swing, with every threshold still holding except a strict dropped-visitors one, which is why it is now 2% and not zero.)
Two failed nightly runs in a row is a regression: bisect the commits since the last green run.

## Run it by hand

You need k6 (`brew install k6`) and a database of its own. **Never point this at a database you care about**:
the seeder refuses to run in production, but it will happily fill a development database.

```sh
# 1. A scratch database with ~150k tasks (about 15 seconds). Same data every run.
createdb task_api_loadtest
export DATABASE_URL=postgres:///task_api_loadtest
bin/rails db:schema:load
bin/rails loadtest:seed            # USERS, PROJECTS, TASKS_PER_PROJECT, WHALE_TASKS, TOKENS to resize
unset DATABASE_URL                 # writes tmp/loadtest/tokens.json

# 2. Run the app the way production does. Rack::Attack is switched off, or the test measures 429s.
createuser -s task_api && createdb -T task_api_loadtest task_api_production
RAILS_ENV=production FORCE_SSL=false ASSUME_SSL=false bin/rails db:prepare   # also creates the cache/queue/cable databases
RAILS_ENV=production FORCE_SSL=false ASSUME_SSL=false RAILS_LOG_LEVEL=warn \
  RAILS_MAX_THREADS=5 RACK_ATTACK_ENABLED=false LOAD_SHEDDING=false PORT=3100 bin/rails server

# 3. Hit it.
k6 run -e BASE_URL=http://localhost:3100 -e RATE=20 -e DURATION=60s loadtest/k6/api.js
k6 run -e BASE_URL=http://localhost:3100 -e RATE=40 -e DURATION=60s --summary-export=summary.json loadtest/k6/api.js
```

Run it once at a low rate first to warm the process (code loading, connection pool, caches), and look
at the per-endpoint lines at the end of the summary: one slow endpoint is hidden in an average.

## Reading the output

- `http_req_duration{name:<endpoint>}` is the latency of one endpoint; the names are in `ENDPOINTS` in the script.
- `dropped_iterations` above zero means the server could not take the load: visitors were turned away
  rather than queued indefinitely. That rate is past the capacity of what you are running.
- Latency that is flat and low and then jumps by 10-50x between two rates is queueing, not a slow query:
  the server has run out of threads. Add capacity (more pods, KEDA does this for workers) or find what
  holds a thread too long.

## Against a deployed environment

Create the tokens with `loadtest:seed` against that environment's database from a shell inside the cluster
(`kubectl exec`), copy `tokens.json` out, and set `BASE_URL`. Do this against **dev or a dedicated
performance environment**, never production, and tell whoever is on call. Throttling (`RACK_ATTACK_ENABLED`) and load shedding (`LOAD_SHEDDING`) must
be off there too, or you are testing the rate limiter and the shedder, not the code. To test shedding itself, leave it on and
read the 503s as the result (see ADR 62).
