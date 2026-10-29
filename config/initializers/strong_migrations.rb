# Refuses migrations that would lock a table or break the old code still serving traffic
# during a rolling deploy (see docs/runbooks/zero-downtime-migrations.md for the patterns).
#
# Migrations up to and including this version predate the check; they ran on empty tables.
StrongMigrations.start_after = 20261029150000

# The oldest PostgreSQL this app supports; the checks adapt to it (e.g. what is safe to add with a default).
StrongMigrations.target_version = 17

# Give up quickly rather than queue behind a long transaction and block every request behind us.
StrongMigrations.lock_timeout = 10.seconds
StrongMigrations.statement_timeout = 1.hour

# Mistakes caught in development and CI should say how to do it safely, not just that it is unsafe.
StrongMigrations.auto_analyze = true
