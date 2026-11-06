# Hosted environment configuration

The Flutter app has one configuration type, `ApiConfig`. Hosted builds set it with dart-defines. The server has one env file, `deploy/.env`, copied from `deploy/.env.example`.

## Client environments

| `APP_ENV` | `API_BASE_URL` | Result |
| --- | --- | --- |
| `local` or unset | unset | Android `http://10.0.2.2:4000`. Other targets `http://127.0.0.1:4000` |
| `local` | any absolute URL, including http on a lab host | That URL |
| `validation` | required `https://...` | That URL. Missing URL or `http://` fails at startup |
| `production` | required `https://...` | That URL. Same rejection rules as validation |

Validation build:

```sh
flutter build apk --dart-define=APP_ENV=validation --dart-define=API_BASE_URL=https://api.example.com
```

Use the owned API hostname after DNS approval. `api.example.com` is a placeholder.

WebSocket URLs replace `https` with `wss` and use path `/realtime/ws`. A validation build cannot fall through to `10.0.2.2` or `127.0.0.1`.

Do not put `DATABASE_URL`, SMTP passwords, `OTP_HMAC_SECRET`, or `TURN_SHARED_SECRET` in dart-defines. TURN credentials are fetched after login.

Do not add a cleartext exception or a certificate bypass for hosted builds. The debug Android manifest still allows cleartext so local debug builds keep working. Release builds do not use that manifest. iOS ATS has no arbitrary-load exception.

`CALL_RELAY_ONLY` remains a separate dart-define for relay-only ICE tests. Leave it unset for normal validation builds.

## Live test harness

`mobile/test/integration/live_two_client_e2e_test.dart` reads process environment `LIVE_E2E`, `API_BASE_URL`, and `DATABASE_URL`. That is the existing CI harness. It may use `http://127.0.0.1:4000`. It does not configure the hosted client.

## Server environment

`deploy/compose.validation.yml` reads `deploy/.env`.

| Variable | Purpose |
| --- | --- |
| `API_DOMAIN` | Name Caddy serves. Placeholder `api.example.com` |
| `ACME_EMAIL` | Certificate expiry contact |
| `TURN_DOMAIN` | Documented DNS name. coturn uses `TURN_REALM` and `TURN_EXTERNAL_IP` |
| `POSTGRES_USER` | Administrator role, default name `pm_admin`. Not the API login |
| `POSTGRES_PASSWORD` | Administrator password |
| `POSTGRES_APP_PASSWORD` | Alphanumeric password for `pm_app` |
| `POSTGRES_DB` | `private_messenger` |
| `VALIDATION_DATABASE_URL` | `pm_app` URL with `pool_max_conns=8` and `sslmode=disable` on the Docker network. Compose passes it to the API and the migrate container as `DATABASE_URL`. The file name avoids a developer shell `DATABASE_URL` replacing the in-network host |
| `OTP_HMAC_SECRET` | Base64, at least 32 decoded bytes |
| `SMTP_*` | STARTTLS submission on port 587 with AUTH PLAIN |
| `TURN_SHARED_SECRET` | Alphanumeric, at least 16 characters. The API refuses a shorter value. Same value reaches coturn. Never the client |
| `TURN_URLS` | UDP TURN URL only, until TCP or TLS TURN is configured |
| `TURN_STUN_URLS` | STUN on 3478 |
| `TURN_TTL_SECONDS` | `600` matches the existing default of 10 minutes |
| `TURN_REALM` | Public TURN hostname |
| `TURN_EXTERNAL_IP` | VPS public IPv4. Required |
| `WS_ALLOWED_ORIGINS` | Empty for Flutter. Set only for a browser origin |

The compose file forces the API process to `APP_ENV=validation`, `APP_HOST=0.0.0.0`, and `APP_PORT=4000`. Do not set `REQUIRE_TLS`, `TLS_CERT_FILE`, or `TLS_KEY_FILE` for this stack. `APP_ENV=production` would demand certificates inside the API and is the wrong mode behind Caddy.

`sslmode=disable` is acceptable only because PostgreSQL has no published port. Do not reuse that URL on a public address.

## DNS

After approval, and only for a zone you control:

| Name | Type | Value |
| --- | --- | --- |
| `api.<owned-domain>` | A | VPS IPv4 |
| `turn.<owned-domain>` | A | VPS IPv4 |

No AAAA record until IPv6 is configured on coturn and on the host. Caddy HTTP-01 needs port 80. Renewal uses the `caddy_data` volume. Deleting that volume forces a new issuance.

TURN media does not go through Caddy. The TURN name is an address record for coturn.

## Secrets

Generate values on the server or on an administrator machine, then put them in `deploy/.env` with mode `0600`. The example file is safe to commit because every secret is a placeholder. A real `.env` is gitignored.

Rotation:

- SMTP password: update `.env`, recreate the API container.
- `OTP_HMAC_SECRET`: update `.env` and recreate the API. Outstanding OTP challenges stop verifying.
- `TURN_SHARED_SECRET`: update `.env`, recreate the API and coturn together. Old credentials fail at coturn.
- `POSTGRES_APP_PASSWORD`: `ALTER ROLE pm_app PASSWORD '...'` inside the database, then update `VALIDATION_DATABASE_URL` and recreate the API. The init script does not run again on an existing volume.
- Session tokens: users log in again. Logout already revokes the current token.

## Flutter builds that must not ship

A validation APK built without `APP_ENV=validation` still points at loopback. Check the defines before handing a build to a device. A build with `APP_ENV=validation` and an `http://` URL fails closed instead of connecting.
