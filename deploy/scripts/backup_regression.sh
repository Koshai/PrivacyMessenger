#!/bin/sh
# Encrypts a dump, restores it into a second database, and checks retention.
# The off-site target is a local directory allowed only for this drill.
set -eu
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
offsite="$work/offsite"
env_file="$work/backup.env"
mkdir -p "$offsite"

cleanup() {
  if [ -n "${cid:-}" ]; then
    docker rm -f "$cid" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

cid=$(docker run -d \
  -e POSTGRES_PASSWORD=regresspass \
  -e POSTGRES_USER=pm_admin \
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
  -c "CREATE DATABASE backup_src OWNER pm_admin;" \
  -c "CREATE ROLE pm_app LOGIN PASSWORD 'regressapp';"
docker exec "$cid" psql -v ON_ERROR_STOP=1 -U pm_admin -d backup_src \
  -c "CREATE TABLE marker (id integer);" \
  -c "INSERT INTO marker (id) VALUES (7);"

cat > "$env_file" <<EOF
POSTGRES_USER=pm_admin
POSTGRES_DB=backup_src
BACKUP_PASSPHRASE=drill-passphrase-1
BACKUP_OFFSITE_TARGET=${offsite}
BACKUP_ALLOW_LOCAL_DRILL=1
EOF

if PM_DOCKER_CONTAINER="$cid" ENV_FILE="$env_file" BACKUP_PASSPHRASE=drill-passphrase-1 \
  BACKUP_OFFSITE_TARGET="$offsite" BACKUP_ALLOW_LOCAL_DRILL=1 \
  "$root/deploy/scripts/backup.sh"; then
  :
else
  echo "backup script failed" >&2
  exit 1
fi

enc=$(find "$offsite" -name 'private_messenger_*.dump.enc' | head -n 1)
if [ -z "$enc" ]; then
  echo "encrypted backup was not written" >&2
  exit 1
fi
# The ciphertext must not be a raw custom-format dump.
if head -c 5 "$enc" | grep -q PGDMP; then
  echo "backup file is still plaintext" >&2
  exit 1
fi

PM_DOCKER_CONTAINER="$cid" ENV_FILE="$env_file" BACKUP_PASSPHRASE=drill-passphrase-1 \
  "$root/deploy/scripts/restore-isolated.sh" "$enc" backup_dst

count=$(docker exec "$cid" psql -U pm_admin -d backup_dst -tA -c "SELECT id FROM marker")
count=$(printf '%s' "$count" | tr -d '[:space:]')
if [ "$count" != "7" ]; then
  echo "restored marker row was ${count}" >&2
  exit 1
fi

# Retention fixture. PRUNE_NOW is 2026-11-05 00:00:00 UTC.
prune_dir="$work/retention"
mkdir -p "$prune_dir"
: > "$prune_dir/private_messenger_20261104T120000Z.dump.enc"
: > "$prune_dir/private_messenger_20261001T120000Z.dump.enc"
: > "$prune_dir/private_messenger_20261002T120000Z.dump.enc"
: > "$prune_dir/private_messenger_20260801T120000Z.dump.enc"
PRUNE_NOW=$(date -u -d "2026-11-05 00:00:00" +%s) \
  "$root/deploy/scripts/backup.sh" prune "$prune_dir"
if [ ! -f "$prune_dir/private_messenger_20261104T120000Z.dump.enc" ]; then
  echo "daily backup was deleted" >&2
  exit 1
fi
if [ ! -f "$prune_dir/private_messenger_20261002T120000Z.dump.enc" ]; then
  echo "weekly backup was deleted" >&2
  exit 1
fi
if [ -f "$prune_dir/private_messenger_20261001T120000Z.dump.enc" ]; then
  echo "older copy in the same week was kept" >&2
  exit 1
fi
if [ -f "$prune_dir/private_messenger_20260801T120000Z.dump.enc" ]; then
  echo "backup older than 8 weeks was kept" >&2
  exit 1
fi

cat > "$work/refuse.env" <<EOF
POSTGRES_USER=pm_admin
POSTGRES_DB=backup_src
BACKUP_PASSPHRASE=drill-passphrase-1
BACKUP_OFFSITE_TARGET=${offsite}
EOF
set +e
BACKUP_PASSPHRASE=drill-passphrase-1 BACKUP_OFFSITE_TARGET="$offsite" \
  ENV_FILE="$work/refuse.env" PM_DOCKER_CONTAINER="$cid" \
  "$root/deploy/scripts/backup.sh"
refuse=$?
set -e
if [ "$refuse" -eq 0 ]; then
  echo "local off-site target was accepted without the drill flag" >&2
  exit 1
fi

echo "backup regression passed"
