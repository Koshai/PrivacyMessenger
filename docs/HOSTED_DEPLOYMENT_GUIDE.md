# Hosted deployment guide

This is a single Ubuntu server with Docker Compose. It is not highly available and it is not a production certification. One disk, one host, and one API process are single points of failure.

Do this only after the deployment commit has been reviewed and after explicit approval to provision the VPS and change DNS. Milestone D stays open until the hosted checks in `docs/HOSTED_VALIDATION_RESULTS.md` have actually been run.

## Images

| Service | Pin | Update |
| --- | --- | --- |
| API | Built from `deploy/Dockerfile.api` with `golang:1.26.10-bookworm` | Rebuild when `backend/go.mod` or the API code changes. Run the Go tests before replacing the running image |
| PostgreSQL | `postgres:17.6` | Stay on major 17 unless the migrations and Go tests pass on a newer major. Write the new tag in the compose file in a reviewed commit |
| Caddy | `caddy:2.8.4` | Replace the tag in a reviewed commit. Certificate data stays in the `caddy_data` volume |
| coturn | `coturn/coturn:4.6.3` | Same tag the local and CI coturn already use. Change it only with a relay test |

The API image build produces a linux/amd64 binary and runs as uid 65532. The VPS does not compile the application.

## Files

| File | Role |
| --- | --- |
| `deploy/compose.validation.yml` | API, PostgreSQL, one-shot migrate, Caddy, coturn |
| `deploy/Caddyfile` | HTTPS for the API hostname and WebSocket proxy |
| `deploy/coturn/turnserver.validation.conf` | TURN template. The secret is substituted at start |
| `deploy/.env.example` | Placeholder names only |
| `deploy/scripts/migrate.sh` | Applies `backend/migrations/*.up.sql` |
| `deploy/scripts/backup.sh` | Custom-format dump |
| `deploy/scripts/restore-isolated.sh` | Restores into a database other than `private_messenger` |

`deploy/compose.yaml` and `deploy/coturn/docker-compose.yml` stay the local stacks. Do not point the VPS at them.

## First boot

1. Install Ubuntu 24.04 and Docker Engine with the Compose plugin. Do not install a second database, a queue, or a metrics stack.
2. Create a deploy user with SSH keys. Disable password SSH after the key works. Restrict SSH by source address when the administrator address is stable.
3. Copy the repository to the server, or copy the `deploy/` directory, the API image, and `backend/migrations`.
4. Copy `deploy/.env.example` to `deploy/.env`. Replace every secret. Keep each value on one line without quotes. `POSTGRES_APP_PASSWORD` and `TURN_SHARED_SECRET` are alphanumeric. `VALIDATION_DATABASE_URL` uses that same application password and the hostname `postgres`. Compose injects it as `DATABASE_URL` inside the containers. Do not `source` this file in a shell. The URL contains `&`.
5. Generate `OTP_HMAC_SECRET` as base64 of at least 32 random bytes.
6. Set `TURN_EXTERNAL_IP` to the VPS public IPv4 address. `203.0.113.10` in the example is documentation-only.
7. Set `API_DOMAIN` and `TURN_REALM` to names you control. Create DNS A records for the API name and the TURN name after approval. Leave IPv6 unset until an AAAA record and coturn IPv6 are both configured.
8. From `deploy/`:

```sh
docker compose --env-file .env -f compose.validation.yml up -d --build
```

9. Confirm `migrate` exited 0. A failed migration leaves the API unstarted. Read `docker compose logs migrate` and fix the SQL error. Do not delete `postgres_data` to hide a failure.
10. Confirm `wget` inside the API container gets `GET /health`. That route does not prove the database is up. Also confirm the API log contains `Database connection failed` on a bad URL, and does not contain OTP values, session tokens, or the TURN secret.
11. Open the guest firewall and the OVH firewall for SSH (restricted), TCP 80, TCP 443, UDP/TCP 3478, and UDP 49160-49260. Do not open 5432 or 4000.
12. Caddy obtains a certificate for `API_DOMAIN` when that name points at this host and port 80 is reachable. Renewal is Caddy's own store in `caddy_data`.

`postgres-init.sh` runs only when the data volume is empty. It creates role `pm_app` and makes that role the database owner. Later password changes are `ALTER ROLE` from an administrator session, not a restart of the init script.

## What is reachable

```text
Clients -- HTTPS/WSS :443 --> Caddy --> API on the edge network
API -- private data network --> PostgreSQL
Clients -- TURN 3478 and UDP 49160-49260 --> coturn
```

PostgreSQL has no host port. The API has no host port. coturn is not attached to the database network. The API also sits on the edge network so SMTP to the public internet can leave the host. `APP_ENV` inside the API container is `validation`, so the process does not terminate TLS itself.

## Migrations

The migrate service is one-shot. It records applied filenames in `schema_migrations`. It does not run `*.down.sql` and it does not truncate application tables. Re-running it skips files that are already recorded. `psql` cannot parse pgx's `pool_max_conns`, so the migrate script removes `pool_*` parameters from the URL before it connects. The API process keeps those parameters.

Each file and its ledger insert run in one transaction. If the file fails, or if `psql` is interrupted, PostgreSQL rolls the file and the ledger row back together. The next run applies that filename again. Files that already committed stay applied.

There is no development seed on this stack.

## Backups

Set `BACKUP_PASSPHRASE` (16 or more characters) and `BACKUP_OFFSITE_TARGET=user@backup-host:/var/backups/privacymessenger` in `deploy/.env`. From `deploy/`:

```sh
sh scripts/backup.sh
```

The script dumps in custom format, encrypts with AES-256-CBC and PBKDF2 (200000 iterations), copies the ciphertext to the off-server target, and deletes the plaintext and the local ciphertext. A path without `user@host:` is refused. `BACKUP_ALLOW_LOCAL_DRILL=1` exists only for the local regression and does not satisfy this procedure.

The dump does not include roles. Recreate `pm_admin` and `pm_app` from the secrets store, then:

```sh
sh scripts/restore-isolated.sh /path/to/private_messenger_<stamp>.dump.enc private_messenger_restore
```

The script refuses the name `private_messenger`. Decrypt uses `BACKUP_PASSPHRASE` and removes the temporary plaintext when it exits.

Retention, applied on the off-server directory:

```sh
sh scripts/backup.sh prune /var/backups/privacymessenger
```

Keep every encrypted copy from the last 14 days. For copies older than 14 days and up to 56 days, keep the newest copy in each ISO week. Delete everything older than 56 days. Run the prune after each successful copy. The VPS does not keep a backup after the copy succeeds.

Take a backup at least once a day. Test an isolated restore from the off-server ciphertext after the first real backup and again at least once every 30 days. A local drill recorded in `docs/HOSTED_VALIDATION_RESULTS.md` is not that VPS test.

## Rollback

1. Keep the previous API image tag on the host until the new one is healthy.
2. `docker compose ... up -d` with the previous image if the new process fails health.
3. Do not roll back a migration by deleting the volume. Restore a dump into a new database and move the API only after the restored schema matches the image you start.
4. Caddy and coturn configuration roll back with the git revision. Certificate data can stay.

## Operations that stay off this host

- `go test` and `flutter test`
- `flutter build`
- `e2eseed`
- Compiling the API with `go run` on the VPS

Build the API image on a workstation or in CI and load it, or build it once during a controlled deploy and then prune build cache. `docker image prune` is safe. `docker volume prune` and `docker compose down -v` delete `postgres_data`.

## Log bounds

Compose sets json-file logs to 10 MB and 3 files per service. Do not raise that without a disk check. Application logs must keep the existing redaction behavior. Do not add message bodies, MLS secrets, OTP codes, session tokens, SDP secrets, or the TURN secret to log lines.

## Single-server failure

A host outage, disk failure, or bad firewall change stops API, database, and TURN together. Calls and login stop. This document does not claim failover.
