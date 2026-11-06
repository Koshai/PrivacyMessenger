#!/bin/sh
# Proves a failed or interrupted migration leaves neither its objects nor a ledger row,
# and that a later run can apply the same filename.
set -eu
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
script="$root/deploy/scripts/migrate.sh"
work=$(mktemp -d)

docker_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s\n' "$1"
  fi
}
fixtures="$work/fixtures"
mkdir -p "$fixtures"

cleanup() {
  if [ -n "${cid:-}" ]; then
    docker rm -f "$cid" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

printf '%s\n' 'CREATE TABLE kept_marker (id integer);' > "$fixtures/001_ok.up.sql"
printf '%s\n' 'CREATE TABLE rolled_back_marker (id integer);' 'SELECT 1/0;' > "$fixtures/002_fail.up.sql"
printf '%s\n' 'CREATE TABLE interrupted_marker (id integer);' 'SELECT pg_sleep(30);' > "$fixtures/003_sleep.up.sql"

cid=$(docker run -d \
  -e POSTGRES_PASSWORD=regresspass \
  -e POSTGRES_USER=pm_admin \
  -v "$(docker_path "$fixtures"):/fixtures" \
  -v "$(docker_path "$script"):/migrate.sh:ro" \
  postgres:17.6)

i=0
until docker exec "$cid" pg_isready -U pm_admin >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -gt 40 ]; then
    echo "postgres did not become ready" >&2
    exit 1
  fi
  sleep 1
done

docker exec "$cid" psql -v ON_ERROR_STOP=1 -U pm_admin -d postgres \
  -c "CREATE DATABASE migrate_regression OWNER pm_admin;"

set +e
docker exec -e DATABASE_URL=postgres://pm_admin:regresspass@127.0.0.1:5432/migrate_regression \
  -e MIGRATIONS_DIR=/fixtures \
  "$cid" sh /migrate.sh
fail_status=$?
set -e
if [ "$fail_status" -eq 0 ]; then
  echo "expected the failing migration to return non-zero" >&2
  exit 1
fi

docker exec "$cid" psql -v ON_ERROR_STOP=1 -U pm_admin -d migrate_regression -tA \
  -c "SELECT filename FROM schema_migrations ORDER BY filename" | grep -qx '001_ok.up.sql'
docker exec "$cid" psql -v ON_ERROR_STOP=1 -U pm_admin -d migrate_regression -tA \
  -c "SELECT to_regclass('public.kept_marker') IS NOT NULL" | grep -qx t
docker exec "$cid" psql -v ON_ERROR_STOP=1 -U pm_admin -d migrate_regression -tA \
  -c "SELECT to_regclass('public.rolled_back_marker') IS NULL" | grep -qx t
docker exec "$cid" psql -v ON_ERROR_STOP=1 -U pm_admin -d migrate_regression -tA \
  -c "SELECT count(*) FROM schema_migrations WHERE filename = '002_fail.up.sql'" | grep -qx 0

rm -f "$fixtures/002_fail.up.sql"

docker exec -d -e DATABASE_URL=postgres://pm_admin:regresspass@127.0.0.1:5432/migrate_regression \
  -e MIGRATIONS_DIR=/fixtures \
  "$cid" sh /migrate.sh

found=""
i=0
while [ "$i" -lt 50 ]; do
  found=$(docker exec "$cid" psql -U pm_admin -d migrate_regression -tA \
    -c "SELECT pid FROM pg_stat_activity WHERE query LIKE '%pg_sleep%' AND pid <> pg_backend_pid() LIMIT 1")
  found=$(printf '%s' "$found" | tr -d '[:space:]')
  if [ -n "$found" ]; then
    break
  fi
  i=$((i + 1))
  sleep 0.2
done
if [ -z "$found" ]; then
  echo "interrupted migration never reached pg_sleep" >&2
  exit 1
fi

docker exec "$cid" psql -U pm_admin -d migrate_regression -c "SELECT pg_terminate_backend(${found})" >/dev/null

i=0
while [ "$i" -lt 50 ]; do
  busy=$(docker exec "$cid" psql -U pm_admin -d migrate_regression -tA \
    -c "SELECT count(*) FROM pg_stat_activity WHERE query LIKE '%pg_sleep%' AND pid <> pg_backend_pid()")
  busy=$(printf '%s' "$busy" | tr -d '[:space:]')
  if [ "$busy" = "0" ]; then
    break
  fi
  i=$((i + 1))
  sleep 0.2
done

docker exec "$cid" psql -v ON_ERROR_STOP=1 -U pm_admin -d migrate_regression -tA \
  -c "SELECT to_regclass('public.interrupted_marker') IS NULL" | grep -qx t
docker exec "$cid" psql -v ON_ERROR_STOP=1 -U pm_admin -d migrate_regression -tA \
  -c "SELECT count(*) FROM schema_migrations WHERE filename = '003_sleep.up.sql'" | grep -qx 0

printf '%s\n' 'CREATE TABLE interrupted_marker (id integer);' > "$fixtures/003_sleep.up.sql"
docker exec -e DATABASE_URL=postgres://pm_admin:regresspass@127.0.0.1:5432/migrate_regression \
  -e MIGRATIONS_DIR=/fixtures \
  "$cid" sh /migrate.sh

docker exec "$cid" psql -v ON_ERROR_STOP=1 -U pm_admin -d migrate_regression -tA \
  -c "SELECT filename FROM schema_migrations WHERE filename = '003_sleep.up.sql'" | grep -qx '003_sleep.up.sql'
docker exec "$cid" psql -v ON_ERROR_STOP=1 -U pm_admin -d migrate_regression -tA \
  -c "SELECT to_regclass('public.interrupted_marker') IS NOT NULL" | grep -qx t

echo "migration regression passed"
