#!/bin/sh
# Restores a custom-format dump into a new database name.
# Refuses the live application database name.
set -eu

dump="${1:?Usage: restore-isolated.sh <dump> [database-name]}"
target="${2:-private_messenger_restore}"
compose_file="${COMPOSE_FILE:-compose.validation.yml}"
env_file="${ENV_FILE:-.env}"

host_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s\n' "$1"
  fi
}

env_value() {
  if [ ! -f "$env_file" ]; then
    return 0
  fi
  grep -E "^$1=" "$env_file" | tail -n 1 | cut -d= -f2- || true
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

plain=""
cleanup() {
  if [ -n "$plain" ] && [ -f "$plain" ]; then
    rm -f "$plain"
  fi
}
trap cleanup EXIT

case "$dump" in
  *.enc)
    if [ -z "${BACKUP_PASSPHRASE:-}" ]; then
      BACKUP_PASSPHRASE=$(env_value BACKUP_PASSPHRASE)
      export BACKUP_PASSPHRASE
    fi
    : "${BACKUP_PASSPHRASE:?Set BACKUP_PASSPHRASE to decrypt the backup}"
    plain=$(mktemp "${TMPDIR:-/tmp}/pm-restore.XXXXXX")
    chmod 600 "$plain"
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -salt \
      -pass env:BACKUP_PASSPHRASE -in "$(host_path "$dump")" -out "$(host_path "$plain")"
    source_dump=$plain
    ;;
  *)
    source_dump=$dump
    ;;
esac

psql_exec() {
  if [ -n "${PM_DOCKER_CONTAINER:-}" ]; then
    docker exec -i "$PM_DOCKER_CONTAINER" psql "$@"
  else
    docker compose --env-file "$env_file" -f "$compose_file" exec -T postgres psql "$@"
  fi
}

psql_exec -v ON_ERROR_STOP=1 -U "$admin" -d postgres \
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${target}' AND pid <> pg_backend_pid();" \
  -c "DROP DATABASE IF EXISTS ${target};" \
  -c "CREATE DATABASE ${target} OWNER pm_app;"

if [ -n "${PM_DOCKER_CONTAINER:-}" ]; then
  docker exec -i "$PM_DOCKER_CONTAINER" \
    pg_restore -U pm_app -d "$target" --no-owner --exit-on-error < "$source_dump"
else
  docker compose --env-file "$env_file" -f "$compose_file" exec -T postgres \
    pg_restore -U pm_app -d "$target" --no-owner --exit-on-error < "$source_dump"
fi

echo "Restored ${dump} into ${target}"
