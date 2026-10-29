#!/bin/bash
# Runs once when the local Postgres container is first created. One server, a database (and role) per
# service: the services share nothing but the server in development; in AWS each can have its own cluster.
set -euo pipefail

create_role_and_dbs() {
  local role="$1" password="$2"; shift 2
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<SQL
CREATE ROLE ${role} LOGIN PASSWORD '${password}' CREATEDB;
SQL
  for db in "$@"; do
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -c "CREATE DATABASE ${db} OWNER ${role};"
  done
}

create_role_and_dbs task_api "${TASK_API_DATABASE_PASSWORD:-task_api}" \
  task_api_production task_api_production_cache task_api_production_queue task_api_production_cable
create_role_and_dbs auth "${AUTH_DATABASE_PASSWORD:-auth}" auth_production
create_role_and_dbs notifications "${NOTIFICATIONS_DATABASE_PASSWORD:-notifications}" notifications_production

# pgvector must be enabled by a superuser before the app's migrations run.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname task_api_production -c "CREATE EXTENSION IF NOT EXISTS vector;"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname auth_production -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;"
