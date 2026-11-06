#!/bin/sh
# Renders the validation coturn config from the environment and starts coturn.
# The shared secret stays in the server environment and is not written to the image.
set -eu

: "${TURN_SHARED_SECRET:?TURN_SHARED_SECRET is required}"
: "${TURN_REALM:?TURN_REALM is required}"
: "${TURN_EXTERNAL_IP:?TURN_EXTERNAL_IP is required}"

case "$TURN_SHARED_SECRET" in
  *[!A-Za-z0-9]*)
    echo "TURN_SHARED_SECRET must be alphanumeric" >&2
    exit 1
    ;;
esac

case "$TURN_REALM" in
  *[!A-Za-z0-9.-]*)
    echo "TURN_REALM must be a hostname" >&2
    exit 1
    ;;
esac

case "$TURN_EXTERNAL_IP" in
  *[!0-9.]*)
    echo "TURN_EXTERNAL_IP must be an IPv4 address" >&2
    exit 1
    ;;
esac

sed \
  -e "s|__TURN_SHARED_SECRET__|${TURN_SHARED_SECRET}|g" \
  -e "s|__TURN_REALM__|${TURN_REALM}|g" \
  -e "s|__TURN_EXTERNAL_IP__|${TURN_EXTERNAL_IP}|g" \
  /etc/coturn/turnserver.conf.template > /tmp/turnserver.conf
chmod 600 /tmp/turnserver.conf

exec turnserver -c /tmp/turnserver.conf
