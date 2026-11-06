# Production TURN validation

External TURN has not been validated. A coturn process that starts, including the local CI loopback job, is not this document's pass.

## What is prepared

`deploy/compose.validation.yml` publishes UDP and TCP 3478 and UDP 49160-49260. TLS port 5349 is not published. `no-tcp-relay` is set. `TURN_URLS` in the example advertises UDP only.

The shared secret is the API `TURN_SHARED_SECRET`. The entrypoint rejects an empty secret and writes the rendered config inside the container with mode 0600. The Flutter build does not receive it.

`external-ip` must be the VPS public IPv4. The example value `203.0.113.10` is not a deployment. A wrong address produces relay candidates that never carry media.

Private, loopback, link-local, and documentation ranges are denied as relay peers. IPv6 is not configured.

The local file `deploy/coturn/docker-compose.yml` is unchanged and remains the loopback/CI configuration, with relay ports 49160-49200.

## Checks that are not done

| Check | Result |
| --- | --- |
| Credential fetch from a public API | Not run |
| coturn accepts a fresh credential | Not run |
| coturn rejects an expired credential | Not run |
| UDP relay between two off-host clients | Not run |
| TCP or TLS relay | Not configured, so not run |
| Relay-only ICE on two devices | Not run |
| Wi-Fi to mobile-data call | Not run |
| Allocation cleanup after hang-up | Not run |
| Abuse attempt toward a private peer address | Not run |

## How to record a future pass

1. Deploy with the real public IP and the real TURN hostname.
2. From an authenticated client, call `GET /calls/ice-config` and confirm the payload has URLs and a username/credential and does not contain the shared secret.
3. Place a relay-only call between two devices that are not on the VPS. Confirm coturn shows an allocation and that media flows.
4. Wait until the credential expiry and confirm a new allocation with the old credential fails.
5. Hang up and confirm the allocation is removed.
6. Write the date, the client networks, and the coturn log evidence into `docs/HOSTED_VALIDATION_RESULTS.md`.

Until those steps exist, the capacity and release rows for external TURN stay open.
