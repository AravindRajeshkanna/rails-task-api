# Testing

How the suite is laid out, what it guards, and what its numbers mean.

```sh
bundle exec rspec                                  # the app (spec/), ~8 s
bundle exec rspec spec gems deploy/lambda          # everything: the app, the shared gems, the AIOps Lambdas (what CI runs)
COVERAGE=1 bundle exec rspec spec gems deploy/lambda   # the same with the coverage floor enforced (CI and bin/ci)
bundle exec rspec spec/requests/tenant_isolation_spec.rb   # any file or directory, on its own
RAILS_ENV=test bin/rails rswag:specs:swaggerize    # regenerate swagger/v1/swagger.yaml after changing an API spec
```

Each of those runs alone: the gem and Lambda specs do not depend on the Rails app having booted, and their
helpers are scoped to their own files so they cannot shadow anything in the app's specs. (`.rspec` used to carry a
`--pattern` listing all three directories, which made every invocation run all of them whatever you passed.)
The three extracted services (`services/*`) have their own bundle, database and `bundle exec rspec`; CI runs
them as a matrix.

## What lives where

| Directory | Kind | What it proves |
| --- | --- | --- |
| `spec/api/` | rswag request specs | The API contract. Each response is validated against a schema and the OpenAPI document is generated from them |
| `spec/requests/` | request specs | Behavior over HTTP: auth, errors, rate limiting, caching and security headers, tenant isolation, journeys |
| `spec/models/`, `spec/db/` | model specs, constraint specs | Validations and associations; that the **database** refuses bad data even when validations are skipped |
| `spec/policies/` | policy specs | Who may do what (pundit-matchers); the security-critical layer |
| `spec/forms/`, `spec/queries/`, `spec/services/`, `spec/jobs/`, `spec/subscribers/` | unit specs | Form objects, query objects, AI/webhook/observability services, background jobs, event subscribers |
| `spec/channels/`, `spec/mailers/` | channel and mailer specs | Action Cable authorization, emails |
| `gems/*/spec`, `deploy/lambda/*/spec` | unit specs | The shared gems and the AIOps Lambdas |
| `deploy/terraform/tests/` | `terraform test`, in CI | The multi-region wiring: what each role (single region, primary, standby) creates and is named, against mocked AWS providers, with no credentials ([ADR 45](decisions.md)) |
| `loadtest/` | k6, nightly in CI | Latency and error thresholds under load, against ~150,000 seeded tasks in production mode ([loadtest/README.md](../loadtest/README.md)) |

Tools: RSpec, FactoryBot, Faker, Shoulda Matchers, pundit-matchers, WebMock (no real HTTP in tests), Bullet
(raises on N+1 and unused eager loading), SimpleCov, rswag.

## Guards that fail the build when someone forgets something

These are the tests worth knowing about, because they turn a convention into a check:

- **`spec/requests/api_docs_spec.rb`**: every `/api/v1` route is in the committed OpenAPI document and nothing
  documented is missing a route. Add an endpoint without an rswag spec and it fails. CI also regenerates the document and
  fails if it differs from the committed one.
- **`spec/requests/tenant_isolation_spec.rb`**: every project-scoped route answers 404 to an outsider, 401 to nobody, and
  403 to a plain member where the action is admin-only; none of those attempts changes any data. The last example
  fails if a route is not in the table, so a new endpoint cannot ship without deciding what each caller gets.
- **`spec/db/constraints_spec.rb`**: CHECK constraints reject bad rows written around the model, and none is left unvalidated.
- **`BaseController`**: `verify_authorized` / `verify_policy_scoped` make a forgotten `authorize` or `policy_scope` raise in
  development and test instead of leaking data.

## Coverage

`COVERAGE=1` turns on SimpleCov (line and branch) over `app/`, `lib/`, `gems/*/lib` and the Lambdas' `lib/`. CI and
`bin/ci` set it and fail under the floor in `spec/spec_helper.rb`:

| | Now | Floor |
| --- | ---: | ---: |
| Line | 94.3% | 92% |
| Branch | 84.1% | 81% |

The floor sits just under the current value, so it catches a drop (code arriving without specs), not a goal to chase.
Override per run with `COVERAGE_MIN_LINE` / `COVERAGE_MIN_BRANCH`. The report is `coverage/index.html`; CI uploads it
as an artifact. Coverage says a line ran, not that anything was asserted about it: the policies, models and
controllers (where mistakes cost something) are at 96-100% and are also covered by the sweeps above. The
lowest-covered files are the glue around real AWS clients (`ai/gateway/remote.rb`, the Lambdas' Kubernetes adapter),
which can only be exercised against the real service. The extracted services' suites are not included in the number.

## Decisions

- **VCR is not used.** Outbound HTTP is webhook delivery (asserted with WebMock, against a stubbed DNS resolver) and AWS
  calls (Bedrock, SNS), which the AWS SDK's own `stub_responses` replaces with typed fixtures. Cassettes would record
  real responses, including whatever secrets and personal data they carry. Revisit if a plain HTTP API provider is added.
- **No parallel test runner.** 950+ examples run in about 20 seconds; parallelism would add per-worker databases and make
  coverage merging fiddly for no gain. Add `parallelize(workers: :number_of_processors)` (or `parallel_tests`) when the
  suite passes ~2 minutes.
- **Time is controlled, never waited for**: `travel_to` / `travel`, never `sleep`.
