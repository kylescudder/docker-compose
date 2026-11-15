#!/bin/sh
# Runs once, when sortarr-db starts with an empty data directory.
# sortarr_owner owns the database and runs migrations (the sortarr-migrate
# one-shot). sortarr_runtime, used by the app, can only read and write rows:
# no DDL and no access to the drizzle migration journal.
set -eu
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
  -v owner_password="$SORTARR_OWNER_PASSWORD" \
  -v runtime_password="$SORTARR_RUNTIME_PASSWORD" <<'SQL'
CREATE ROLE sortarr_owner LOGIN PASSWORD :'owner_password';
CREATE ROLE sortarr_runtime LOGIN PASSWORD :'runtime_password' CONNECTION LIMIT 8;
CREATE DATABASE sortarr OWNER sortarr_owner;
REVOKE ALL ON DATABASE sortarr FROM PUBLIC;
GRANT CONNECT ON DATABASE sortarr TO sortarr_owner, sortarr_runtime;
-- Only the superuser may open the maintenance database.
REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;
\connect sortarr
ALTER SCHEMA public OWNER TO sortarr_owner;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO sortarr_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE sortarr_owner IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO sortarr_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE sortarr_owner IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO sortarr_runtime;
SQL
