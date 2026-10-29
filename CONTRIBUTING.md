# Contributing

Thanks for helping. This is a Rails 8.1 API with a few extracted services around it; the quickest way to get oriented is the
[README](README.md), then [docs/architecture/overview.md](docs/architecture/overview.md). Why things are the way they are:
[docs/decisions.md](docs/decisions.md). What has been done and what is next: [docs/roadmap.md](docs/roadmap.md).

## Set up

```sh
mise install                       # Ruby from mise.toml (or any Ruby matching .ruby-version)
brew install postgresql@17 pgvector   # PostgreSQL 17 with the vector extension (apt: postgresql-17 postgresql-17-pgvector)
bin/setup --skip-server            # gems, databases, schema
bundle exec rspec                  # should be green before you change anything
bin/dev                            # the server on :3000, docs at /api-docs
```

Docker Compose runs the whole platform (API, Auth, AI, Notifications, mocks of AWS): see [deploy/README.md](deploy/README.md).

## Workflow

1. Branch from `main` (`feature/…`, `fix/…`, `docs/…`).
2. Make a change **with its specs**. A bug fix starts with a failing spec.
3. Run `bin/ci` (RuboCop, bundler-audit, Brakeman, the specs with the coverage floor). It is what GitHub Actions runs.
4. Open a pull request; the template lists what reviewers look for. Keep it to one idea; say what you did **not** verify.

## Conventions

- **Controllers are thin:** authorize, call a query/command/form, render. Business rules live in models, policies, commands
  (`app/commands`, writes), queries (`app/queries`, reads) and form objects (`app/forms`, validated input).
- **Every action authorizes** and every index uses `policy_scope`; `Api::V1::BaseController` makes a forgotten one raise.
  Outsiders get `404`, not `403` ([decision 4](docs/decisions.md)).
- **One error envelope**, built by `ErrorSerializer`. Never `render json: { error: ... }` by hand.
- **Serialize with Alba resources**, never `as_json`. Output is an explicit list of attributes.
- **A new endpoint** needs: a route, a policy, request specs (happy path, 401, 404/403, validation), an rswag spec in `spec/api/`
  (then `RAILS_ENV=test bin/rails rswag:specs:swaggerize` and commit `swagger/v1/swagger.yaml`), an entry in the isolation matrix in
  `spec/requests/tenant_isolation_spec.rb`, and a line in [CHANGELOG.md](CHANGELOG.md). Specs fail until you do each.
- **Migrations** follow [docs/runbooks/zero-downtime-migrations.md](docs/runbooks/zero-downtime-migrations.md); `strong_migrations`
  enforces it. Constraints belong in the database as well as the model.
- **N+1 queries** fail the specs (Bullet). Add `includes`/`preload`, and assert query counts on new list endpoints with `count_queries`.
- **Style** is RuboCop (omakase plus the Lint, Rails, Performance and complexity cops). `bin/rubocop -a` fixes most things. Do not add to
  `.rubocop_todo.yml`; fix the code or, with a reason, disable the cop on that line.
- **Secrets** never go in git (`.env`, `config/master.key`, Terraform state). `.env.example` documents every variable.
- **Commits:** imperative subject under ~72 characters, a body that says *why*.

## Tests

See [docs/testing.md](docs/testing.md). In short: `bundle exec rspec` (the app, ~8 s), `bundle exec rspec spec gems deploy/lambda`
(everything), `cd services/auth && bundle exec rspec` (a service). Coverage is a floor on the whole suite, not a target for a file.

## Reporting a security problem

Do not open a public issue. Contact the repository owner privately; see [docs/security.md](docs/security.md).

## License

By contributing you agree that your contributions are licensed under the project's license ([LICENSE](LICENSE)).
