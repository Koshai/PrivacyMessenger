# Messaging envelopes API (crypto-agnostic + MLS routing)

Authenticated endpoints that store **opaque** ciphertext only. The server never decrypts application payloads.

## Open conversation

`POST /conversations` `{ "peer_user_id": "<uuid>" }` → conversation metadata  
Requires accepted friendship.

Response may include `mls_group_id_hex` once established.

## Establish MLS group mapping

`PUT /conversations/{conversationID}/mls-group`

```json
{ "mls_group_id_hex": "<hex>" }
```

- Initiator binds conversation → MLS group once
- `409` if a different group is already set

## Send envelope (idempotent)

`POST /conversations/{conversationID}/envelopes`

```json
{
  "client_message_id": "stable-client-id",
  "ciphertext_b64": "<base64 opaque bytes>",
  "content_type": "application/mls-message"
}
```

Allowed content types:

- `application/opaque`
- `application/mls-message` (requires MLS group established)
- `application/mls-welcome`
- `application/mls-commit`
- `application/mls-proposal`
- `application/octet-stream`

- `201` created
- `200` idempotent replay of the same `(conversation, sender, client_message_id)`
- `409` if `application/mls-message` is sent before MLS group mapping exists

Ordering: clients must process envelopes by `created_at` ascending (and `seq` when present). Welcome before application ciphertext for joiners.

## History / sync / ack

- `GET /conversations/{conversationID}/envelopes?limit=&before_id=&before_created_at=`
- `GET /envelopes/pending`
- `POST /envelopes/{envelopeID}/ack` → `204`

## Realtime hints

`GET /realtime/ws` (Bearer or `?access_token=`)

Push events are **hints** only. After reconnect, clients must call pending sync. PostgreSQL remains the durable source of truth.
