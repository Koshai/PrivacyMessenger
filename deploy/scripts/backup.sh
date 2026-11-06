#!/bin/sh
# Dumps the validation database in custom format.
# Encrypt the file and copy it off the VPS. This host must not hold the only copy.
set -eu

compose_file="${COMPOSE_FILE:-compose.validation.yml}"
env_file="${ENV_FILE:-.env}"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
out="${1:-./backups/private_messenger_${stamp}.dump}"

# Read one key from a Compose env file. Do not source the file: URLs contain & and ?.
env_value() {
  grep -E "^$1=" "$env_file" | tail -n 1 | cut -d= -f2-
}

POSTGRES_USER=$(env_value POSTGRES_USER)
POSTGRES_DB=$(env_value POSTGRES_DB)

mkdir -p "$(dirname "$out")"

docker compose --env-file "$env_file" -f "$compose_file" exec -T postgres \
  pg_dump -U "${POSTGRES_USER:-pm_admin}" -d "${POSTGRES_DB:-private_messenger}" \
  -Fc --no-owner > "$out"

echo "Wrote ${out}"
echo "Roles are not inside this dump. Recreate pm_admin and pm_app from the secrets store before restore."
echo "Encrypt this file and store it off the VPS."
