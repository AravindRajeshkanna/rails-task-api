#!/bin/bash
# Runs once, when the Postgres accessory first initializes its data directory.
# config/database.yml expects these databases next to the primary one.
set -e

for database in task_api_production_cache task_api_production_queue task_api_production_cable; do
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -c "CREATE DATABASE $database"
done
