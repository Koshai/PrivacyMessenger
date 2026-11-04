# Messaging envelopes API (crypto-agnostic)

Authenticated endpoints that store **opaque** ciphertext only. This is **not** a claim of E2EE; client encryption is pending Milestone C licensing approval.

## Open conversation

`POST /conversations` `{ "peer_user_id": "<uuid>" }` → `{ "conversation_id", "created_at" }`  
Requires accepted friendship.

## Send envelope (idempotent)

`POST /conversations/{conversationID}/envelopes`

```json
{
  "client_message_id": "stable-client-id",
  "ciphertext_b64": "<base64 opaque bytes>",
  "content_type": "application/opaque"
}
```

- `201` created
- `200` idempotent replay of the same `(conversation, sender, client_message_id)`

## History / sync / ack

- `GET /conversations/{conversationID}/envelopes?limit=&before_id=&before_created_at=`
- `GET /envelopes/pending`
- `POST /envelopes/{envelopeID}/ack` → `204`

Authorization: only conversation participants. Server never inspects ciphertext bytes.
