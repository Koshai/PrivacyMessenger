# TURN deployment (coturn)

PrivacyMessenger uses **coturn** with time-limited REST credentials (`use-auth-secret`). The API signs usernames with `TURN_SHARED_SECRET`. That secret is never sent to Flutter.

Example process config: `deploy/coturn/turnserver.conf`.  
Example compose (local ports, non-production secret default): `deploy/coturn/docker-compose.yml`.

Hosted validation on one VPS is a separate stack: `deploy/compose.validation.yml` and `deploy/coturn/turnserver.validation.conf`. That stack uses relay UDP `49160–49260`, injects the shared secret at start, and does not enable TURN over TLS. Starting that container is not evidence of an external relay. See `docs/PRODUCTION_TURN_VALIDATION.md`.

## DNS and TLS

- Publish a stable name such as `turn.example.test` that resolves to the coturn host.
- UDP/TCP `3478` is the standard TURN/STUN listener.
- TLS TURN (`turns:`) listens on `5349` and needs a certificate whose name matches the URL clients receive (`TURN_URLS`).
- Point `cert` / `pkey` at that certificate. Do not commit key material.

## Ports

| Port | Purpose |
| --- | --- |
| 3478/udp | STUN and TURN over UDP |
| 3478/tcp | TURN over TCP |
| 5349/tcp | TURN over TLS when certificates are installed |
| 49160–49200/udp (example) | Relay media. Size the range for peak concurrent calls |

`min-port` / `max-port` in coturn must match the firewall allowance. Clients receive these allocations as relay candidates; the range must be reachable from the Internet, not only from the API host. The hosted validation stack uses `49160–49260`. The local example remains `49160–49200`.

## Firewall and NAT

- Allow inbound 3478/udp, 3478/tcp, 5349/tcp, and the relay UDP range.
- If coturn sits behind NAT, set `external-ip` to the public address clients must use. A wrong external IP produces relay candidates that gather but never carry media.
- Do not rely on SDP success as proof of relay. Check nominated candidate pairs and a media or data-channel probe.

## Shared secret

API environment (server only):

```
TURN_SHARED_SECRET=<random 32+ bytes>
TURN_URLS=turn:turn.example.test:3478?transport=udp,turn:turn.example.test:3478?transport=tcp,turns:turn.example.test:5349?transport=tcp
TURN_STUN_URLS=stun:turn.example.test:3478
TURN_TTL_SECONDS=600
TURN_REALM=turn.example.test
```

Coturn must use the same value as `--static-auth-secret` / `static-auth-secret`.

TTL must be between 60 seconds and 1 hour. The API rejects anything outside that range at startup when a secret is set. With no secret, `GET /calls/ice-config` returns `503 TURN unavailable`.

Credential shape:

- username = `<unix-expiry>:<user-uuid>`
- credential = base64(HMAC-SHA1(secret, username))

Flutter requests a new config for each peer connection. It does not store a permanent TURN password.

## Bandwidth and egress

Relayed audio is roughly 50–100 kbit/s per direction; video can be 300 kbit/s–2 Mbit/s per direction depending on capture. Budget **two relays** (caller and callee) when both sides are relay-only. Watch coturn allocation count, relay byte counters, and host egress. Shrink `max-port` or rate-limit the API (30 credential requests/minute/user, single instance) if the host is abused.

## Secret rotation

1. Generate a new secret.
2. Deploy it to the API and coturn together (brief overlap requires running two coturn listeners or accepting in-flight calls to fail ICE refresh).
3. Existing peer connections keep their current allocation until they end. New calls use the new secret.
4. Remove the old secret from disk and secret manager. Do not commit either value.

## Abuse prevention and monitoring

- Keep coturn off the public Internet until the secret is set. `lt-cred-mech` + `use-auth-secret` rejects anonymous allocations.
- `no-multicast-peers` is set in the example config.
- Disable the coturn CLI (`no-cli`) on production hosts.
- Log allocation failures and bandwidth. Alert on unexpected egress.
- The API rate limit is per process. Put a shared limiter in front if you run more than one API instance.
- Do not log `TURN_SHARED_SECRET` or full credential responses in access logs.

## Local relay check

```
docker run -d --name pm-coturn -p 3478:3478/udp -p 3478:3478/tcp -p 52000-52040:52000-52040/udp coturn/coturn:4.6.3 \
  -n --log-file=stdout --listening-port=3478 --fingerprint --lt-cred-mech \
  --use-auth-secret --static-auth-secret=local-dev-turn-secret --realm=privacy.test \
  --external-ip=127.0.0.1 --min-port=52000 --max-port=52040 --no-cli --no-multicast-peers

# from backend/
TURN_RELAY_TEST=1 TURN_TEST_SECRET=local-dev-turn-secret \
  TURN_TEST_URL=turn:127.0.0.1:3478?transport=udp \
  go test ./internal/turn/ -run TestRelayOnlyDataChannel -v
```

`local-dev-turn-secret` is for this loopback check only.
