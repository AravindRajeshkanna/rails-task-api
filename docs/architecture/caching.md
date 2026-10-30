# Caching strategy

Four layers, each answering a different question, and one rule for all of them: **a cache key must contain whatever makes the answer different, so that invalidating is never a step anyone can forget.**

| Layer | What it holds | Key / validator | Invalidated by | Where |
| --- | --- | --- | --- | --- |
| **Request** (Active Record query cache) | repeated identical queries inside one request | the SQL | the end of the request, or any write in it | Rails, on by default |
| **Application** (Solid Cache) | a project's task counts by status; a project's analytics report; an AI project summary | `project.cache_key_with_version` (its `updated_at`), + the report's parameters and the date; the summary has a TTL | **event**: a task `touch`es its project, so the version in the key changes and the old entry is simply never read again; **time**: the analytics key includes today's date, the AI summary expires | `Project#stats`, `AnalyticsController`, `Ai::ProjectSummary` |
| **HTTP** (the client's own cache) | any response a client already has | `ETag` (computed from the body) | the next request: `Cache-Control: no-cache, private` makes the client revalidate with `If-None-Match` and the server answers `304` with no body | `Rack::ETag`, `ApplicationController#set_cache_headers`; `spec/requests/http_caching_spec.rb` |
| **Edge** (CDN) | nothing, on purpose | n/a | n/a | see below |

## Why invalidation is by key, not by delete

An entry is written under a key derived from the data's version. A change to the data changes the key, so the stale entry is never read again and ages out of the cache by itself (Solid Cache evicts by age and size). Nothing deletes anything, so there is no code path where a writer can forget to invalidate, and nothing to get wrong under concurrency (two writers cannot leave a deleted-then-repopulated-with-old-data entry behind).
The price is that every change to a task writes the project's `updated_at` (28% of task write throughput, measured; [performance.md](../performance.md#what-the-indexes-cost-measured)) and that old entries occupy space until they age out. Both are the right trade at this scale, and the trigger for the alternative (a counter table, a debounced touch) is written down.

## What is not cached, and why

- **Lists and single records** are not cached server-side: they are index-ordered `LIMIT` queries that cost 0.1-3 ms, and a cache in front of them would add a lookup and an invalidation problem to save less than the lookup costs. They are served by the replica instead when that is wanted (`ReplicaRouting`, [ADR 60](../decisions.md)).
- **Anything per-person in a shared cache.** Cache keys that are shared between callers (the analytics report is the same for every member) are only used after the caller has been authorized for the project; the cache never decides who may see something.
- **Responses at the edge.** Every API response depends on who is asking (`Vary: Authorization`), so a CDN may not store them and `private` says so. Putting CloudFront in front still helps (TLS termination close to the caller, connection reuse to the origin, WAF and DDoS shielding) without caching a byte. What could be cached at the edge, and is not yet: the OpenAPI document and the Swagger UI (static, public), and attachment downloads, which are already signed, short-lived redirects (10 minutes); a CDN in front of those would need CloudFront signed URLs and an origin access control instead of the app signing them. That is a change to how files are served, not to caching, and has not been needed.

## Failure behavior

The cache is allowed to be wrong about being up, never about being right. Solid Cache swallows transient database errors and (since read-only mode) refused writes, so a cache outage costs recomputation, not requests; a hit never depends on the writer being healthy; and rate limiting, which also uses it, degrades to unlimited rather than to an error ([ADR 46](../decisions.md)).
