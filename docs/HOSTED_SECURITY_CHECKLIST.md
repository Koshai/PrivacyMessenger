# Hosted security checklist

Use this on the validation VPS. Checking a box here before the host exists does not close it. This environment is one server. It is not a high-availability or production certification.

## Access

- [ ] SSH keys only. Password authentication disabled after a key login works.
- [ ] SSH restricted to the administrator source addresses when those addresses are known.
- [ ] Unattended security updates enabled for Ubuntu, with a reboot window.
- [ ] Docker socket usable only by the administrator group.
- [ ] `deploy/.env` mode `0600` and absent from git.

## Network

- [ ] Guest firewall and OVH firewall allow SSH, TCP 80, TCP 443, UDP/TCP 3478, and UDP 49160-49260.
- [ ] TCP 5432 is closed on the public address.
- [ ] TCP 4000 is closed on the public address.
- [ ] TURN TLS 5349 stays closed until a certificate is installed and `no-tcp-relay` is deliberately removed.
- [ ] coturn `external-ip` is the public IPv4 of this host.
- [ ] IPv6 listeners stay off until AAAA records and coturn IPv6 are both set.

## Application

- [ ] API image runs as uid 65532.
- [ ] `APP_ENV` for the API process is `validation`. `REQUIRE_TLS` is unset.
- [ ] Clients use `https` and `wss`. No certificate bypass in the hosted build.
- [ ] `GET /health` is the only unauthenticated probe, and it returns status only.
- [ ] PostgreSQL role `pm_app` is the API login. `pm_admin` is not in `DATABASE_URL`.
- [ ] `pm_app` owns the application database so it can apply migrations. The compensating control is that the database port is not published.
- [ ] `e2eseed` is not run against this database.
- [ ] One API container. In-process rate limits are not a cluster control.

## TURN abuse

- [ ] Shared secret is long, alphanumeric, and identical in the API and coturn.
- [ ] Credential TTL is 600 seconds unless a shorter test TTL is recorded.
- [ ] Relay port range matches the firewall.
- [ ] Private and non-global peer ranges stay denied.
- [ ] CLI is disabled.
- [ ] Logs do not include the shared secret.

## Secrets and logs

Do not log message plaintext, MLS secrets, private identity keys, OTP values, session tokens, SDP secrets, or the TURN shared secret. The existing HTTP error log redacts tokens. Container logs rotate at 10 MB times 3 files.

- [ ] OTP request and verify responses were sampled and do not contain the code.
- [ ] A failed SMTP attempt was sampled and does not contain the SMTP password.
- [ ] ice-config responses contain short-lived credentials and not `TURN_SHARED_SECRET`.

## Data

- [ ] `backup.sh` produced an encrypted copy on a different machine. The VPS does not still hold the plaintext or the only ciphertext.
- [ ] Off-server retention is 14 daily copies and the newest copy in each week for 8 weeks.
- [ ] An isolated restore from that ciphertext succeeded on this host within the last 30 days.
- [ ] Roles `pm_admin` and `pm_app` are recorded in the secrets store because the dump uses `--no-owner`.
- [ ] Volume `postgres_data` is excluded from any prune command.

## Incident

1. Stop the API container if credential leakage is suspected. Rotate the affected secret. Recreate the API and, for the TURN secret, coturn.
2. Revoke sessions by having users log in again after an `OTP_HMAC_SECRET` or session-store incident. Logout already revokes the presented token.
3. Collect `docker compose ps`, the last health result, disk free space, and memory. Do not attach message databases or `.env` to a ticket.
4. A host compromise includes the database and the TURN secret. Treat that as a full secret rotation and a database restore review.

## Accepted residual risk

- One host. Disk loss without an off-server copy loses the accounts.
- The application role can change schema.
- Call-binding lookup is not scoped to a call id. Mismatch fails closed. See `docs/CALLING_KNOWN_LIMITATIONS.md`.
- The MLS-to-inbox crash window drops one binding and fails closed.
- TURN over TLS is not enabled.
- Rate limits for calling, crypto, and TURN reset when the API process restarts and are not shared by a second replica.
