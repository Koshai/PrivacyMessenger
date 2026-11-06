#!/bin/sh
# Applies backend/migrations/*.up.sql in filename order.
# A failed file stops the container. Applied files are recorded and are not run again.
# This does not drop schema and does not apply *.down.sql.
set -eu

: "${DATABASE_URL:?DATABASE_URL is required}"
dir="${MIGRATIONS_DIR:-/migrations}"

# pgx accepts pool_max_conns. psql's libpq rejects it.
psql_url=$(printf '%s' "$DATABASE_URL" | sed -E 's/([?&])pool_[^=&]+=[^&]*&?/\1/g; s/[?&]$//')

psql "$psql_url" -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE IF NOT EXISTS schema_migrations (
  filename TEXT PRIMARY KEY,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
SQL

for file in $(find "$dir" -maxdepth 1 -type f -name '*.up.sql' | sort); do
  name=$(basename "$file")
  case "$name" in
    *[!A-Za-z0-9._-]*)
      echo "refusing unexpected migration filename: $name" >&2
      exit 1
      ;;
  esac
  applied=$(psql "$psql_url" -tA -v ON_ERROR_STOP=1 \
    -c "SELECT 1 FROM schema_migrations WHERE filename = '${name}'")
  if [ "$applied" = "1" ]; then
    echo "skip ${name}"
    continue
  fi
  echo "apply ${name}"
  psql "$psql_url" -v ON_ERROR_STOP=1 --single-transaction -f "$file"
  psql "$psql_url" -v ON_ERROR_STOP=1 \
    -c "INSERT INTO schema_migrations (filename) VALUES ('${name}')"
done

echo "migrations complete"
