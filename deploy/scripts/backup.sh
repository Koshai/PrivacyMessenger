#!/bin/sh
# Custom-format dump, encrypted, then copied off this machine.
# Plaintext is removed before the script exits. A local directory is accepted
# only when BACKUP_ALLOW_LOCAL_DRILL=1, and that copy does not meet the off-server rule.
#
# Retention on the off-server directory (backup.sh prune <dir>):
# keep every copy from the last 14 days, and the newest copy in each ISO week
# for copies up to 56 days old. Delete the rest.
set -eu

compose_file="${COMPOSE_FILE:-compose.validation.yml}"
env_file="${ENV_FILE:-.env}"
plain=""
enc=""

env_value() {
  if [ ! -f "$env_file" ]; then
    return 0
  fi
  grep -E "^$1=" "$env_file" | tail -n 1 | cut -d= -f2-
}

host_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s\n' "$1"
  fi
}

wipe() {
  if [ -z "${1:-}" ] || [ ! -f "$1" ]; then
    return 0
  fi
  if command -v shred >/dev/null 2>&1; then
    shred -u "$1"
  else
    rm -f "$1"
  fi
}

stamp_epoch() {
  raw=$1
  year=$(printf '%.4s' "$raw")
  month=$(printf '%s' "$raw" | cut -c5-6)
  day=$(printf '%s' "$raw" | cut -c7-8)
  hour=$(printf '%s' "$raw" | cut -c10-11)
  minute=$(printf '%s' "$raw" | cut -c12-13)
  second=$(printf '%s' "$raw" | cut -c14-15)
  date -u -d "${year}-${month}-${day} ${hour}:${minute}:${second}" +%s
}

stamp_week() {
  raw=$1
  year=$(printf '%.4s' "$raw")
  month=$(printf '%s' "$raw" | cut -c5-6)
  day=$(printf '%s' "$raw" | cut -c7-8)
  date -u -d "${year}-${month}-${day}" +%G-W%V
}

prune_backups() {
  dir=${1:?Usage: backup.sh prune <offsite-directory>}
  now=${PRUNE_NOW:-$(date -u +%s)}
  day=86400
  newest=$(mktemp)
  trap 'rm -f "$newest"' EXIT
  : > "$newest"
  for file in "$dir"/private_messenger_*.dump.enc; do
    [ -f "$file" ] || continue
    base=$(basename "$file")
    stamp=$(printf '%s' "$base" | sed -n 's/^private_messenger_\([0-9]\{8\}T[0-9]\{6\}Z\)\.dump\.enc$/\1/p')
    if [ -z "$stamp" ]; then
      continue
    fi
    epoch=$(stamp_epoch "$stamp")
    week=$(stamp_week "$stamp")
    age=$((now - epoch))
    if [ "$age" -le $((14 * day)) ]; then
      continue
    fi
    if [ "$age" -gt $((56 * day)) ]; then
      rm -f "$file"
      echo "deleted ${base}"
      continue
    fi
    current=$(grep -E "^${week} " "$newest" || true)
    if [ -z "$current" ]; then
      printf '%s %s %s\n' "$week" "$epoch" "$file" >> "$newest"
      continue
    fi
    current_epoch=$(printf '%s' "$current" | cut -d' ' -f2)
    current_path=$(printf '%s' "$current" | cut -d' ' -f3-)
    if [ "$epoch" -gt "$current_epoch" ]; then
      rm -f "$current_path"
      echo "deleted $(basename "$current_path")"
      grep -v -E "^${week} " "$newest" > "${newest}.next" || true
      mv "${newest}.next" "$newest"
      printf '%s %s %s\n' "$week" "$epoch" "$file" >> "$newest"
    else
      rm -f "$file"
      echo "deleted ${base}"
    fi
  done
  echo "retention applied in ${dir}"
}

copy_offsite() {
  enc=$1
  name=$(basename "$enc")
  case "$BACKUP_OFFSITE_TARGET" in
    *:*)
      scp "$enc" "${BACKUP_OFFSITE_TARGET%/}/${name}"
      ;;
    *)
      if [ "${BACKUP_ALLOW_LOCAL_DRILL:-}" != "1" ]; then
        echo "BACKUP_OFFSITE_TARGET must be user@host:/path" >&2
        echo "BACKUP_ALLOW_LOCAL_DRILL=1 is only for a restore drill on this machine." >&2
        exit 1
      fi
      mkdir -p "$BACKUP_OFFSITE_TARGET"
      cp "$enc" "${BACKUP_OFFSITE_TARGET%/}/${name}"
      echo "local drill copy only; this file is not an off-server backup" >&2
      ;;
  esac
}

if [ "${1:-}" = "prune" ]; then
  prune_backups "$2"
  exit 0
fi

cleanup() {
  status=$?
  wipe "$plain"
  if [ "$status" -ne 0 ]; then
    wipe "$enc"
    exit "$status"
  fi
}
trap cleanup EXIT

if [ -z "${BACKUP_PASSPHRASE:-}" ]; then
  BACKUP_PASSPHRASE=$(env_value BACKUP_PASSPHRASE)
  export BACKUP_PASSPHRASE
fi
if [ -z "${BACKUP_OFFSITE_TARGET:-}" ]; then
  BACKUP_OFFSITE_TARGET=$(env_value BACKUP_OFFSITE_TARGET)
fi
if [ -z "${BACKUP_ALLOW_LOCAL_DRILL:-}" ]; then
  BACKUP_ALLOW_LOCAL_DRILL=$(env_value BACKUP_ALLOW_LOCAL_DRILL)
fi

: "${BACKUP_PASSPHRASE:?Set BACKUP_PASSPHRASE to 16 or more characters}"
if [ "${#BACKUP_PASSPHRASE}" -lt 16 ]; then
  echo "BACKUP_PASSPHRASE must be at least 16 characters" >&2
  exit 1
fi
: "${BACKUP_OFFSITE_TARGET:?Set BACKUP_OFFSITE_TARGET to user@host:/path}"

case "$BACKUP_OFFSITE_TARGET" in
  *[!A-Za-z0-9@:/_.~-]*)
    echo "BACKUP_OFFSITE_TARGET contains unsupported characters" >&2
    exit 1
    ;;
  *:*)
    ;;
  *)
    if [ "${BACKUP_ALLOW_LOCAL_DRILL:-}" != "1" ]; then
      echo "BACKUP_OFFSITE_TARGET must be user@host:/path" >&2
      echo "BACKUP_ALLOW_LOCAL_DRILL=1 is only for a restore drill on this machine." >&2
      exit 1
    fi
    ;;
esac

POSTGRES_USER=$(env_value POSTGRES_USER)
POSTGRES_DB=$(env_value POSTGRES_DB)
POSTGRES_USER=${POSTGRES_USER:-pm_admin}
POSTGRES_DB=${POSTGRES_DB:-private_messenger}

stamp=$(date -u +%Y%m%dT%H%M%SZ)
plain=$(mktemp "${TMPDIR:-/tmp}/pm-backup.XXXXXX")
chmod 600 "$plain"

if [ -n "${PM_DOCKER_CONTAINER:-}" ]; then
  docker exec -i "$PM_DOCKER_CONTAINER" \
    pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc --no-owner > "$plain"
else
  docker compose --env-file "$env_file" -f "$compose_file" exec -T postgres \
    pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc --no-owner > "$plain"
fi

enc="${TMPDIR:-/tmp}/private_messenger_${stamp}.dump.enc"
openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
  -pass env:BACKUP_PASSPHRASE -in "$(host_path "$plain")" -out "$(host_path "$enc")"
chmod 600 "$enc"
wipe "$plain"
plain=""

copy_offsite "$enc"
wipe "$enc"

echo "Encrypted backup copied to ${BACKUP_OFFSITE_TARGET}"
echo "Roles are not inside the dump. Recreate pm_admin and pm_app before restore."
echo "Retention: 14 daily copies, plus the newest copy in each week for 8 weeks, on the off-server store."
