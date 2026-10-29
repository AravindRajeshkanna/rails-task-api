## What and why

<!-- The problem, and the idea of the change. Link the issue or roadmap item. -->

## How it was verified

<!-- What you ran, and what you did NOT run. "CI green" is not a description. -->
- [ ] `bin/ci` passes locally
- [ ] New behavior has specs (a bug fix has the failing spec first)

## Reviewer checklist

- [ ] Every new action authorizes, every new index scopes, and the new routes are in `spec/requests/tenant_isolation_spec.rb`
- [ ] Endpoints are documented (`spec/api/…`, `swagger/v1/swagger.yaml` regenerated) and in [CHANGELOG.md](../CHANGELOG.md)
- [ ] Migrations are safe for a rolling deploy ([runbook](../docs/runbooks/zero-downtime-migrations.md)); constraints are in the database too
- [ ] No N+1 (Bullet is green), no secrets, no new `.rubocop_todo.yml` entries
- [ ] A non-obvious decision is in [docs/decisions.md](../docs/decisions.md)

## Risk and rollback

<!-- What could go wrong in production, and how to undo it (revert, flag, expand/contract). -->
