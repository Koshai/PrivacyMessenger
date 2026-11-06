#!/bin/sh
# Restores a custom-format dump into a new database name.
# Refuses the live application database name.
set -eu

dump="${1:?Usage: restore-isolated.sh <dump> [database-name]}"
target="${2:-private_messenger_restore}"
compose_file="${COMPOSE_FILE:-compose.validation.yml}"
env_file="${ENV_FILE:-.env}"

env_value() {
  grep -E "^$1=" "$env_file" | tail -n 1 | cut -d= -f2-
}

admin=$(env_value POSTGRES_USER)
if [ -z "$admin" ]; then
  admin=pm_admin
fi

case "$target" in
  private_messenger)
    echo "refusing to restore over private_messenger" >&2
    exit 1
    ;;
  *[!A-Za-z0-9_]*)
    echo "database name must contain only letters, digits, and underscores" >&2
    exit 1
    ;;
esac

if [ ! -f "$dump" ]; then
  echo "dump not found: $dump" >&2
  exit 1
fi

docker compose --env-file "$env_file" -f "$compose_file" exec -T postgres \
  psql -v ON_ERROR_STOP=1 -U "$admin" -d postgres \
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${target}' AND pid <> pg_backend_pid();" \
  -c "DROP DATABASE IF EXISTS ${target};" \
  -c "CREATE DATABASE ${target} OWNER pm_app;"

docker compose --env-file "$env_file" -f "$compose_file" exec -T postgres \
  pg_restore -U pm_app -d "$target" --no-owner --exit-on-error < "$dump"

echo "Restored ${dump} into ${target}"
