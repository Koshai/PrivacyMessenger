#!/bin/sh
# Runs once, on an empty PostgreSQL data directory, as the official entrypoint.
# Creates the application role and gives it ownership of the application database.
set -eu

: "${POSTGRES_USER:?POSTGRES_USER is required}"
: "${POSTGRES_DB:?POSTGRES_DB is required}"
: "${POSTGRES_APP_PASSWORD:?POSTGRES_APP_PASSWORD is required}"

case "$POSTGRES_DB" in
  *[!A-Za-z0-9_]*)
    echo "POSTGRES_DB must contain only letters, digits, and underscores" >&2
    exit 1
    ;;
esac

case "$POSTGRES_APP_PASSWORD" in
  *[!A-Za-z0-9]*)
    echo "POSTGRES_APP_PASSWORD must be alphanumeric so the init script can quote it safely" >&2
    exit 1
    ;;
esac

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<EOF
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'pm_app') THEN
    CREATE ROLE pm_app LOGIN PASSWORD '${POSTGRES_APP_PASSWORD}';
  ELSE
    ALTER ROLE pm_app WITH LOGIN PASSWORD '${POSTGRES_APP_PASSWORD}';
  END IF;
END
\$\$;
GRANT CONNECT ON DATABASE ${POSTGRES_DB} TO pm_app;
ALTER DATABASE ${POSTGRES_DB} OWNER TO pm_app;
EOF
