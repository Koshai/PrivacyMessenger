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

## Envelope ordering

Responses include `conversation_seq` (monotonic per conversation, allocated in the same DB transaction as the insert). Clients **must** process by `(conversation_id, conversation_seq)` ascending, with Welcome before Commit/application when ranks collide.

## Realtime hints

`GET /realtime/ws`

1. Connect **without** credentials in the URL (`access_token` query is rejected).
2. Send first text frame: `{"type":"auth","token":"<session token>"}`.
3. Server replies `{"type":"connected",...}` or closes the socket.
4. Server re-validates the session periodically and emits `session_revoked` on logout/replacement.

Push events are **hints** only. After reconnect, clients must call pending sync. PostgreSQL remains the durable source of truth.
