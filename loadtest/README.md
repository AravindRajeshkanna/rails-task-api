# Load testing

[k6](https://k6.io) scripts and a data generator. The results of the last run, and what they do and do
not tell you, are in [docs/performance.md](../docs/performance.md).

## What it does

`k6/api.js` simulates people visiting the API at a fixed **arrival rate** (the open model: visitors turn up
whether or not the server keeps up, which is how real traffic behaves). A visit is:

- **85% browsing:** list projects, list a project's tasks (default order, filtered and sorted, text search),
  open a task, load analytics, load the activity feed.
- **15% writing:** create a task, update it, comment on it.
- **20% of visits go to one "whale" project** holding 50,000 tasks, because the queries that are fine at a
  thousand rows and slow at fifty thousand are the ones worth finding.

Thresholds fail the run (exit code 99) if reads go over p95 400 ms / p99 1 s, writes over p95 600 ms, or more
than 1% of requests fail.

## Run it

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
  RAILS_MAX_THREADS=5 RACK_ATTACK_ENABLED=false PORT=3100 bin/rails server

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
performance environment**, never production, and tell whoever is on call. Throttling (`RACK_ATTACK_ENABLED`) must
be off there too, or you are testing the rate limiter.
