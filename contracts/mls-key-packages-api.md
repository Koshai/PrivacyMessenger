# MLS identity and key-package API

Authenticated endpoints. The server stores **opaque** public keys and key-package bytes only. It never holds private signing material.

## Server-mediated identity limits

- Registration proves possession of an authenticated **session device**, not human identity.
- Fingerprints (`fingerprint_hex` = SHA-256 of the public identity key) are a foundation for user-visible safety-number UX.
- Users must still compare fingerprints out-of-band; the server can lie or be compromised.

## Register identity

`POST /crypto/identity`

```json
{ "public_key_b64": "..." }
```

- `201` created / `200` idempotent same key
- `409` if a different public key is submitted for the same device (continuity)
- Device must belong to the session user

## Upload key packages

`POST /crypto/key-packages` `{ "packages_b64": ["..."], "ttl_seconds": 604800 }` → `204`

## Claim (one-time)

`POST /crypto/users/{userID}/key-packages/claim` (friends only)

Atomically reserves then consumes one unexpired package.

## Peer identities

`GET /crypto/users/{userID}/identities` → `{ "identities": [{ "device_id", "fingerprint_hex", "public_key_b64", "updated_at" }] }`

## Pool status

`GET /crypto/key-packages/status` → `{ "available", "needs_replenish", "target_pool_size" }`
