-- One-time, per environment: a database and a least-privilege role for each service on the shared Aurora cluster.
-- Run it as the master user (its password is in the secret named by `terraform output database_master_secret_arn`),
-- from a pod in the cluster, because the database is not reachable from the internet:
--
--   kubectl -n task-api run psql --rm -it --restart=Never --image=postgres:17 --env PGSSLMODE=require \
--     --env PGHOST=<database_endpoint> --env PGUSER=postgres --env PGPASSWORD='<master password>' -- psql -f - < deploy/scripts/bootstrap-databases.sql
--
-- The passwords below are placeholders: substitute the database_password values Terraform stored in Secrets Manager
-- (aws secretsmanager get-secret-value --secret-id task-api/<env>/api, .../auth, .../notifications), e.g. with psql -v.
\set ON_ERROR_STOP on

-- The Task API: primary + Solid Cache/Queue/Cable databases (see config/database.yml)
CREATE ROLE task_api LOGIN PASSWORD :'api_password';
CREATE DATABASE task_api_production OWNER task_api;
CREATE DATABASE task_api_production_cache OWNER task_api;
CREATE DATABASE task_api_production_queue OWNER task_api;
CREATE DATABASE task_api_production_cable OWNER task_api;

-- The Auth service
CREATE ROLE auth LOGIN PASSWORD :'auth_password';
CREATE DATABASE auth_production OWNER auth;

-- The Notification service
CREATE ROLE notifications LOGIN PASSWORD :'notifications_password';
CREATE DATABASE notifications_production OWNER notifications;

-- Extensions need a privileged role once; the services' migrations then use them.
\connect task_api_production
CREATE EXTENSION IF NOT EXISTS vector;       -- pgvector: task embeddings
\connect auth_production
CREATE EXTENSION IF NOT EXISTS pgcrypto;     -- gen_random_uuid() for user ids

-- Services cannot see each other's databases.
\connect postgres
REVOKE CONNECT ON DATABASE task_api_production, task_api_production_cache, task_api_production_queue, task_api_production_cable, auth_production, notifications_production FROM PUBLIC;
GRANT CONNECT ON DATABASE task_api_production, task_api_production_cache, task_api_production_queue, task_api_production_cable TO task_api;
GRANT CONNECT ON DATABASE auth_production TO auth;
GRANT CONNECT ON DATABASE notifications_production TO notifications;
