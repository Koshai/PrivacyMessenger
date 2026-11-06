# Hosted infrastructure audit

**Date:** 2026-11-05
**Baseline:** `e67adf62c7cd8c3d23301c227fa4c94b09a9d1dc`
**Target:** one OVHcloud VPS-1 class host (2 vCPU, 4 GB RAM, 40 GB disk, Ubuntu 24.04, x86-64), Docker Compose
**Milestone D:** open
**Milestone E:** not started

This audit reads the repository at the D7 baseline. It does not treat older docs as the implementation. Resource figures below are labeled measured or estimate. No figure here was taken on an OVHcloud VPS.

## Gate A

No critical architectural or security defect blocks preparing the deployment files.

These items block a claim that hosted validation has passed. They do not block preparing the stack:

- No VPS, DNS zone, SMTP account, or external TURN path has been provisioned.
- Physical Android and iPhone checks from D7 are still open.
- Call-binding lookup is not scoped to a call id (medium, left unchanged).
- A crash between MLS consumption and inbox persistence still drops that binding (medium, left unchanged).

Deployment preparation continues through local files, local automated checks, commit, and push. It stops before provisioning or DNS changes.

## Requirements matrix

| Requirement | Repository state at the baseline | Hosted preparation |
| --- | --- | --- |
| Go API | `backend/cmd/api`, Go 1.26.10 | Prebuilt image `deploy/Dockerfile.api` |
| PostgreSQL | Migrations `000001` through `000010`, image `postgres:17` locally | `postgres:17.6` on a private network, same SQL files |
| Email OTP | Real SMTP with STARTTLS in `smtp_otp_sender.go` | Credentials from `deploy/.env`, not from the image |
| OpenMLS messaging | Device-side state, server stores ciphertext | Unchanged |
| Friends and devices | Existing HTTP routes, one active session per account | Unchanged |
| WebSocket signaling | `GET /realtime/ws` | Caddy proxies the API host; shell client now uses that path |
| TURN credentials | HMAC-SHA1 REST, secret stays on the server | Same secret rendered into coturn at start |
| HTTPS | `APP_ENV=production` terminates TLS inside the API | Validation terminates TLS at Caddy |
| Persistent database | Docker volume in local compose | Named volume `postgres_data` |
| Off-server backup | Not implemented | `deploy/scripts/backup.sh` plus a documented off-server copy |
| Privacy-safe logs | HTTP error log redacts tokens | Container logs capped; no new plaintext logging |
| Flutter hosted URL | Hardcoded loopback | `APP_ENV` and `API_BASE_URL` dart-defines |

## A1. Backend

| Item | Finding |
| --- | --- |
| Go version | `go 1.26.10` in `backend/go.mod` |
| Entry point | `backend/cmd/api/main.go` |
| Listen address | `APP_HOST` / `APP_PORT`. Empty values become `127.0.0.1:4000` |
| Health | `GET /health` returns `{"status":"ok"}`. It does not query PostgreSQL |
| Readiness | No separate readiness route. Startup `db.Ping` fails the process if the database is down |
| Auth | `POST /auth/request-otp`, `POST /auth/verify-otp`, `GET /auth/me`, `POST /auth/logout` |
| OTP | HMAC secret `OTP_HMAC_SECRET` (base64, at least 32 bytes). SMTP via `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_FROM_EMAIL`, `SMTP_FROM_NAME` |
| SMTP behavior | STARTTLS is required. AUTH PLAIN is required. Port 465 implicit TLS is not implemented. Errors returned to callers do not include the OTP or the SMTP password |
| Sessions | Login revokes older sessions for that account and revokes prior MLS device identities |
| Friends | `/friends` and `/friends/requests` |
| Messaging | `/conversations/{id}/envelopes`. Ciphertext longer than 64 KiB is rejected |
| MLS packages | Crypto routes under the existing crypto handler. Rate limit 60/minute/user, in process |
| WebSocket | `GET /realtime/ws`. First frame is auth JSON, maximum 8 KiB. `WS_ALLOWED_ORIGINS` is optional |
| Calling | `/calls` and the offer, answer, ICE, accept, and hang-up routes. SDP cap 64 KiB. Signaling rate 60/minute/user, in process |
| TURN | `GET /calls/ice-config`. Username `expiry:user-uuid`, credential HMAC-SHA1. Default TTL 10 minutes. Secret unset returns 503. Limit 30/minute/user, in process |
| Background work | Ring expiry about every 5 seconds |
| Shutdown | SIGINT/SIGTERM, 10 second `Shutdown` |
| Pool | `pgxpool` with no coded `MaxConns`. The URL parameter `pool_max_conns` is honored. Default without it is `max(4, NumCPU)` |
| Body limits | Auth and OTP bodies 4096 bytes. Messaging and signaling enforce their own size caps after read |
| Timeouts | `ReadHeaderTimeout` 5 seconds |
| Rate limits | OTP 3 requests / 15 minutes in PostgreSQL. Friend requests 10 / 15 minutes in PostgreSQL. Calling, crypto, and TURN limits are in-process and apply to one API process |

`APP_ENV=production` or `REQUIRE_TLS=true` exits unless `TLS_CERT_FILE` and `TLS_KEY_FILE` exist. The validation stack sets `APP_ENV=validation` and does not set `REQUIRE_TLS`. Clients still use HTTPS to Caddy. The API speaks HTTP only on the Docker networks.

Localhost assumptions: the default bind is loopback. The validation compose sets `APP_HOST=0.0.0.0` and does not publish port 4000.

## A2. Database

| Item | Finding |
| --- | --- |
| Version | Local and CI use PostgreSQL 17. Validation pins `postgres:17.6` |
| Migrations | Raw SQL files. CI applies them with `psql`. The API does not migrate on startup |
| Extensions | None required |
| Connection | `DATABASE_URL` |
| Transactions | Login and other writes use explicit transactions where the service already does |
| Startup | A failed ping stops the process. Schema is not dropped or reseeded |
| Persistence | PostgreSQL is the server system of record. OpenMLS state and the call-binding inbox live on the device |
| Seed data | `backend/cmd/e2eseed` is a test tool. The validation compose does not run it |
| Retention | No server-side message wipe job was found. OTP and session rows follow the existing auth tables |

The validation migrate container applies `*.up.sql` in order. The file and its `schema_migrations` insert commit in one transaction. A failed or interrupted file leaves a non-zero container status and rolls both back. Down migrations are not applied.

## A3. Flutter

| Item | Finding |
| --- | --- |
| Baseline URL | Android `http://10.0.2.2:4000`. Other targets `http://127.0.0.1:4000` |
| WebSocket | Scheme follows the API URL (`https` becomes `wss`). Conversation screen used `/realtime/ws`. The authenticated shell previously kept the origin path |
| Token storage | Existing secure storage. Unchanged |
| TLS | No certificate bypass was found. Release Android manifest does not set `usesCleartextTraffic`. Debug manifest allows cleartext for local development |
| iOS ATS | No `NSAppTransportSecurity` exceptions. Default ATS allows HTTPS |
| TURN | Credentials come from `GET /calls/ice-config` after login. The shared secret is not in the client |
| Logout | Clears the local call seed and the binding inbox. Contact pins remain |

Hosted builds use the existing `ApiConfig` type with `APP_ENV` and `API_BASE_URL`. `validation` and `production` reject a missing URL and reject any scheme other than `https`. `local` keeps the previous loopback behavior. The live OpenMLS harness still reads process environment `API_BASE_URL` and can use `http://127.0.0.1:4000`. That harness is not the hosted client.

The shell realtime client now sets path `/realtime/ws`, matching the conversation screen and the server route.

## A4. Calling and TURN

D7 behavior is unchanged:

- One MLS decrypt path.
- Call bindings use content type `application/call-key-binding` and are stored before the server ack.
- Remote playback stays tied to the authenticated call generation.
- Enrollment timeout is not treated as revocation. A `false` enrollment result ends the call.
- Logout clears the local call seed and inbox.

| Finding | Severity | Action in this pass |
| --- | --- | --- |
| Inbox `find` matches sender account and device, not call id. A newer binding from the same device can be selected for another call and then fail closed on statement mismatch | Medium | Documented. Not refactored |
| Process death after OpenMLS consumes ciphertext and before the inbox write loses the binding. The call fails closed | Medium | Documented. Not refactored |
| External coturn, firewall, and two-network media have not been executed | High for release evidence, not a code defect | Config prepared. Result stays not run |
| TURN secret unset disables credentials with HTTP 503 | Low, fail-closed | Validation env requires the secret |
| CI relay test is loopback and uses `deploy/coturn/docker-compose.yml` | Informational | That file is unchanged |

Credential shape remains `username = expiry-unix:user-uuid` and `credential = base64(HMAC-SHA1(secret, username))`.

## A5. Deployment and CI

Existing assets reused:

- `deploy/compose.yaml` remains the local PostgreSQL-only stack on `127.0.0.1:55433`.
- `deploy/coturn/docker-compose.yml` remains the local/CI coturn command line, including the non-production default secret.
- `backend/migrations` stay the schema source.
- `.github/workflows/ci.yml` jobs remain `go`, `flutter`, `ios-compile`, `live-e2e`, `turn-relay`, and `android-compile`.
- `live-e2e` builds the API binary before the health wait. That order stays.

There was no API Dockerfile, Caddyfile, or validation compose file at the baseline. Those are added beside the local files rather than replacing them.

## A6. Resources

Planning allowances from the milestone (not measurements): API 300 MB, PostgreSQL 600 MB, coturn 150 MB, Caddy 100 MB, operating system 700 MB, headroom about 2.1 GB.

Container memory ceilings in `deploy/compose.validation.yml` are host-protection limits, not measured working sets: API 512 MB, PostgreSQL 1 GB, coturn 256 MB, Caddy 128 MB. They were chosen above the planning allowances and below a sum that fills 4 GB by itself. Lower them only after a VPS measurement. If the kernel kills a container, raise that ceiling and record the measurement before changing the VPS size.

PostgreSQL settings in the compose file are the suggested starting point: `shared_buffers=256MB`, `effective_cache_size=1GB`, `work_mem=4MB`, `maintenance_work_mem=64MB`, `max_connections=30`. The API URL sets `pool_max_conns=8`. That leaves connections for the migrate container, `pg_dump`, and an administrator. `shm_size` is 512 MB because `shared_buffers` uses shared memory and the Docker default is too small.

No idle RSS, image size, startup time, or migration duration had been measured at audit time. Later local checks, if they run, are recorded in `docs/HOSTED_RESOURCE_BUDGET.md` and are not VPS capacity.

Disk planning, not partitions: OS 6 GB, images 5 GB, database 10 GB, logs 3 GB, free reserve 16 GB. Log rotation is `json-file` at 10 MB times 3 files per service. Image pruning must not delete the `postgres_data` volume.

The VPS is not a build machine. The API image is built beforehand. Flutter and Go test suites are not part of the compose file. Redis, RabbitMQ, Kubernetes, Elasticsearch, and a metrics stack are not added.

## Compatibility

| Area | Compatible with this VPS plan |
| --- | --- |
| Go API as a single prebuilt container | Yes |
| PostgreSQL 17 | Yes. Pin is 17.6, same major as CI |
| Caddy TLS and WebSocket proxy | Yes |
| coturn on published 3478 and UDP 49160-49260 | Yes, after the guest and OVH firewalls allow those ports |
| In-process rate limits | Yes for one API container. A second replica would not share them |
| `APP_ENV=production` behind Caddy | No, unless the API process itself holds certificates. Use `validation` |
| Compiling Flutter or the full test suite on the VPS | No |

## Blockers before Gate 4

1. Explicit approval to provision the VPS and to change DNS.
2. An owned domain for `api` and `turn` names.
3. An SMTP account that offers STARTTLS and AUTH PLAIN on port 587.
4. Alphanumeric secrets generated on the server, stored outside git.
5. Physical devices and an external network path for the integration matrix.

## Recommended changes applied after this audit

- Multi-stage non-root API image.
- Validation compose with private PostgreSQL, Caddy, and coturn.
- Migration runner over the existing SQL files.
- Backup and isolated-restore scripts.
- Flutter `APP_ENV` / `API_BASE_URL` without a second configuration type.
- Shell WebSocket path set to `/realtime/ws`.
